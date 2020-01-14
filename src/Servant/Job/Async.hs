{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
module Servant.Job.Async
  -- Essentials
  ( AsyncJobAPI
  , AsyncJobAPI'
  , AsyncJobsAPI
  , AsyncJobsAPI'
  , AsyncJobsServer
  , MonadAsyncJobs

  , JobID
  , JobStatus
  , job_id
  , job_log
  , job_status

  , JobInput(JobInput)
  , job_input
  , job_callback

  , JobOutput(JobOutput)
  , job_output

  , JobFunction(JobFunction)
  , SimpleJobFunction
  , simpleJobFunction
  , ioJobFunction
  , pureJobFunction
  , newIOJob

  , JobEnv
  , HasJobEnv(job_env)
  , defaultDuration
  , newJobEnv

  , EnvSettings
  , defaultSettings
  , env_duration

  , simpleServeJobsAPI
  , serveJobsAPI

  , JobsStats(..)
  , serveJobEnvStats

  , deleteExpiredJobs
  , deleteExpiredJobsPeriodically
  , deleteExpiredJobsHourly

  -- Re-exports
  , Safety(..)

  -- Internals
  , Job
  , job_async
  , deleteJob
  , checkID
  , newJob
  , getJob
  , pollJob
  , killJob
  , waitJob
  )
  where

import Control.Applicative
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, waitCatch, poll, cancel)
import Control.Concurrent.MVar (MVar, newMVar, readMVar, modifyMVar_)
import Control.Exception.Base (Exception, SomeException(SomeException), throwIO)
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Except
import Control.Monad.Reader
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (isNothing)
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics hiding (to)
import Network.HTTP.Client hiding (Proxy, path)
import Prelude hiding (log)
import Servant
import Servant.API.Flatten
import Servant.Job.Client (clientMCallback)
import Servant.Job.Types
import Servant.Job.Core
import Servant.Job.Utils (jsonOptions)
import Servant.Client hiding (manager, ClientEnv)
import qualified Servant.Client as S

data Job event a = Job
  { _job_async   :: !(Async a)
  , _job_get_log :: !(IO [event])
  }

makeLenses ''Job

type instance SymbolOf (Job event output) = "job"

data JobEnv event output = JobEnv
  { _jenv_jobs    :: !(Env (Job event output))
  , _jenv_manager :: !Manager
  }

makeLenses ''JobEnv

instance HasEnv (JobEnv event output) (Job event output) where
  _env = jenv_jobs

class HasEnv jenv (Job event output)
   => HasJobEnv jenv event output
    | jenv -> event, jenv -> output
  where
    job_env :: Lens' jenv (JobEnv event output)

instance HasJobEnv (JobEnv event output) event output where
  job_env = id

type MonadAsyncJobs env err event output m =
  ( MonadServantJob env err (Job event output) m
  , HasJobEnv env event output
  , Exception err
  , ToJSON event
  , ToJSON output
  )

newJobEnv :: EnvSettings -> Manager -> IO (JobEnv event output)
newJobEnv settings manager = JobEnv <$> newEnv settings <*> pure manager

deleteJob :: (MonadIO m, MonadReader env m, HasEnv env (Job event output))
          => JobID 'Safe -> m ()
deleteJob i = do
  env <- view _env
  deleteItem env i

deleteExpiredJobs :: JobEnv event output -> IO ()
deleteExpiredJobs = deleteExpiredItems gcJob . view jenv_jobs
  where
    gcJob job = cancel $ job ^. job_async

deleteExpiredJobsPeriodically :: Int -> JobEnv event output -> IO ()
deleteExpiredJobsPeriodically delay env = do
  threadDelay delay
  deleteExpiredJobs env
  deleteExpiredJobsPeriodically delay env

deleteExpiredJobsHourly :: JobEnv event output -> IO ()
deleteExpiredJobsHourly = deleteExpiredJobsPeriodically hourly
  where
    hourly = 1000000 * 60 * 60

newtype JobFunction env err event input output = JobFunction
  { runJobFunction ::
      forall m.
        ( MonadReader env m
        , MonadError  err m
        , MonadIO         m
        ) => input -> (event -> IO ()) -> m output
  }

jobFunction :: ( forall m
               . ( MonadReader env m
                 , MonadError  err m
                 , MonadIO         m
                 )
                 => (input -> (event -> m ()) -> m output)
               )
            -> JobFunction env err event input output
jobFunction f = JobFunction (\i log -> f i (liftIO . log))

type SimpleJobFunction event input output =
  JobFunction (JobEnv event output) ServerError event input output

simpleJobFunction :: (input -> (event -> IO ()) -> IO output)
                  -> SimpleJobFunction event input output
simpleJobFunction f = JobFunction (\i log -> liftIO (f i log))

newJob :: forall env err event input output m callbacks
        . ( MonadAsyncJobs env err event output m
          , Traversable callbacks
          )
       => JobFunction env err event input output
       -> JobInput callbacks input -> m (JobStatus 'Safe event)
newJob task i = do
  env <- ask
  let jenv = env ^. job_env
  liftIO $ do
    log <- newMVar []
    let mkJob = async $ do
          out <- runExceptT $
                  (`runReaderT` env) $
                     runJobFunction task (i ^. job_input) (liftIO . pushLog log)
          postCallback $ either mkChanError mkChanResult out
          either throwIO pure out

    (jid, _) <- newItem (jenv ^. jenv_jobs)
                        (Job <$> mkJob <*> pure (readLog log))
    pure $ JobStatus jid [] IsRunning

  where
    postCallback :: ChanMessage error event input output -> IO ()
    postCallback m =
      forM_ (i ^. job_callback) $ \url ->
        undefined
        {-
        liftIO (runClientM (clientMCallback m)
                (S.ClientEnv (jenv ^. jenv_manager)
                             (url ^. base_url) Nothing))
        -}
    pushLog :: MVar [event] -> event -> IO ()
    pushLog m e = do
      postCallback $ mkChanEvent e
      modifyMVar_ m (pure . (e :))

    readLog :: MVar [event] -> IO [event]
    readLog = readMVar

ioJobFunction :: (input -> IO output) -> JobFunction env err event input output
ioJobFunction f = JobFunction (const . liftIO . f)

pureJobFunction :: (input -> output) -> JobFunction env err event input output
pureJobFunction = ioJobFunction . (pure .)

newIOJob :: MonadAsyncJobs env err event output m
         => IO output -> m (JobStatus 'Safe event)
newIOJob m = newJob (JobFunction (\_ _ -> liftIO m)) (JobInput () Nothing)

getJob :: MonadAsyncJobs env err event output m => JobID 'Safe -> m (Job event output)
getJob jid = view env_item <$> getItem jid

jobStatus :: JobID 'Safe -> Maybe Limit -> Maybe Offset -> [event] -> States -> JobStatus 'Safe event
jobStatus jid limit offset log =
  JobStatus jid (maybe id (take . unLimit)  limit $
                 maybe id (drop . unOffset) offset log)

pollJob :: MonadIO m => Maybe Limit -> Maybe Offset
        -> JobID 'Safe -> Job event a -> m (JobStatus 'Safe event)
pollJob limit offset jid job = do
  -- It would be tempting to ensure that the log is consistent with the result
  -- of the polling by "locking" the log. Instead for simplicity we read the
  -- log after polling the job. The edge case being that the log shows more
  -- items which would tell that the job is actually finished while the
  -- returned status is running.
  r   <- liftIO . poll $ job ^. job_async
  log <- liftIO $ job ^. job_get_log
  pure . jobStatus jid limit offset log
       $ maybe IsRunning (either (const IsFailure) (const IsFinished)) r


killJob :: (MonadIO m, MonadReader env m, HasEnv env (Job event output))
        => Maybe Limit -> Maybe Offset
        -> JobID 'Safe -> Job event a -> m (JobStatus 'Safe event)
killJob limit offset jid job = do
  liftIO . cancel $ job ^. job_async
  log <- liftIO $ job ^. job_get_log
  deleteJob jid
  pure $ jobStatus jid limit offset log IsKilled

waitJob :: MonadServantJob env err (Job event output) m
        => Bool -> JobID 'Safe -> Job event a -> m (JobOutput a)
waitJob alsoDeleteJob jid job = do
  r <- either err pure =<< liftIO (waitCatch $ job ^. job_async)
  -- NOTE one might prefer not to deleteJob here and ask the client to
  -- manually killJob.
  --
  -- deleteJob:
  --   Pros: no need to killJob manually (less code, more efficient)
  --   Cons:
  --     * if the client miss the response to waitJob, it cannot
  --       pollJob or waitJob again as it is deleted.
  --     * the client cannot call pollJob/killJob after the waitJob to get
  --       the final log
  --
  -- Hence the alsoDeleteJob parameter
  when alsoDeleteJob $ deleteJob jid
  pure $ JobOutput r

  where
    err e = serverError $ err500 { errBody = LBS.pack $ show e }

serveJobsAPI :: forall env err m event input output ctI ctO
              . MonadAsyncJobs env err event output m
             => JobFunction env err event input output
             -> AsyncJobsServerT' ctI ctO NoCallbacks event input output m
serveJobsAPI f
    =  newJob f
  :<|> wrap' killJob
  :<|> wrap' pollJob
  :<|> (wrap . waitJob) False

  where
    wrap :: forall a. (JobID 'Safe -> Job event output -> m a) -> JobID 'Unsafe -> m a
    wrap g jid' = do
      jid <- checkID jid'
      job <- getJob jid
      g jid job

    wrap' g jid' limit offset = wrap (g limit offset) jid'

-- `serveJobsAPI` specialized to the `Handler` monad.
simpleServeJobsAPI :: forall event input output.
                      ( FromJSON input
                      , ToJSON   event
                      , ToJSON   output
                      )
                   => JobEnv event output
                   -> SimpleJobFunction event input output
                   -> AsyncJobsServer event input output
simpleServeJobsAPI env fun =
  hoistServer (Proxy :: Proxy (AsyncJobsAPI event input output)) transform (serveJobsAPI fun)
  where
    transform :: forall a. ReaderT (JobEnv event output) Handler a -> Handler a
    transform = flip runReaderT env

data JobsStats = JobsStats
  { job_count  :: !Int
  , job_active :: !Int
  }
  deriving (Generic)

instance ToJSON JobsStats where
  toJSON = genericToJSON $ jsonOptions "job_"

-- this API should be authorized to admins only
serveJobEnvStats :: JobEnv event output -> Server (Get '[JSON] JobsStats)
serveJobEnvStats env = liftIO $ do
  jobs <- view env_map <$> readMVar (env ^. jenv_jobs . env_state_mvar)
  active <- length <$> mapM (fmap isNothing . poll . view (env_item . job_async)) jobs
  pure $ JobsStats
    { job_count  = IntMap.size jobs
    , job_active = active
    }
