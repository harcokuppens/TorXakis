{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
{-# LANGUAGE DeriveGeneric #-}
-- |
module TorXakis.Lib.CommonCore where

import           Control.Concurrent.MVar       (putMVar, takeMVar)
import           Control.Concurrent.STM.TQueue (writeTQueue)
import           Control.Concurrent.STM.TVar   (modifyTVar', readTVarIO)
import           Control.Exception             (SomeException, catch)
import           Control.Monad.Except          (ExceptT, throwError)
import           Control.Monad.State           (lift, runStateT)
import           Control.Monad.STM             (atomically)
import           Data.Aeson                    (FromJSON, ToJSON)
import           Data.Semigroup                ((<>))
import           Data.Text                     (Text)
import qualified Data.Text                     as T
import           GHC.Generics                  (Generic)
import           Lens.Micro                    ((.~), (^.))

import           EnvCore                       (IOC)
import           EnvData                       (Msg (TXS_CORE_SYSTEM_ERROR))
import           Name                          (Name)
import           TorXakis.Lens.TxsDefs         (ix)
import qualified TxsCore                       as Core
import           TxsDDefs                      (Action)
import           TxsDefs                       (ModelDef)

import           TorXakis.Lib.Session

-- | How a step is described
data StepType = NumberOfSteps Int
              | AnAction Action
    --           | GoTo StateNumber
    --           | Reset -- ^ Go to the initial state.
    --           | Rewind Steps
              deriving (Show, Eq, Generic)

-- TODO: Types like 'StepType' are needed by the clients of 'txs-webserver'. So
-- to avoid introducing a dependency 'txs-lib' we could create a new package
-- called 'txs-lib-data', or something similar.
-- TODO: discuss with Jan: do we need a `Tree` step here?
instance ToJSON StepType
instance FromJSON StepType

lookupModel :: Session -> Name -> ExceptT Text IO ModelDef
lookupModel s mn = do
    tdefs <- lift $ runIOC s Core.txsGetTDefs
    maybe
        (throwError $ "No model named " <> mn)
        return (tdefs ^. ix mn)

-- | Run an IOC action, using the initial state provided at the session, and
-- modifying the end-state accordingly.
--
-- Two `runIOC` action won't be run in parallel. If an IOC action is pending,
-- then a subsequent call to `runIOC` will block till the operation is
-- finished.
--
-- Do NOT nest multiple runIOC(E) calls, otherwise a deadlock will occur.
runIOC :: Session -> IOC a -> IO a
runIOC s act = runIOC' `catch` reportErrorFixMVar
    where
      runIOC' = do
          -- The GHC implementation of MVar's guarantees fairness in the access to
          -- the critical sections delimited by `takeMVar` and `putMVar`.
          takeMVar (s ^. pendingIOC)
          st <- readTVarIO (s ^. sessionState)
          (r, st') <- runStateT act (st ^. envCore)
          atomically $ modifyTVar' (s ^. sessionState) (envCore .~ st')
          putMVar (s ^. pendingIOC) ()
          return r
      reportErrorFixMVar :: SomeException -> IO a
      reportErrorFixMVar err = do
          -- There's no pending IOC anymore, we release the lock.
          putMVar (s ^. pendingIOC) ()
          reportError s err

-- | Run an IOC action but wrap the results in an exception.
--
-- Do NOT nest multiple runIOC(E) calls, otherwise a deadlock will occur.
runIOCE :: Show err => Session -> IOC (Either err a) -> ExceptT Text IO a
runIOCE s act = do
    er <- lift $ runIOC s act
    case er of
        Left eMsg -> throwError . T.pack . show $ eMsg
        Right res -> return res


-- | Run a read-only IOC action which doesn't modify the state.
--
-- Can be run in parallel with a runIOC(E) or one or more runReadOnlyIOC
-- functions.
--
-- Not thread-safe.
runReadOnlyIOC :: Session -> IOC a -> IO a
runReadOnlyIOC s act = runIOC' `catch` reportError s
    where
      runIOC' = do
          st <- readTVarIO (s ^. sessionState)
          (r, _) <- runStateT act (st ^. envCore)
          return r

-- | Run a read-only IOC action but wrap the results in an exception.
--
-- Can be run in parallel with a runIOC(E) or one or more runReadOnlyIOC
-- functions.
--
-- Not thread-safe.
runReadOnlyIOCE :: Show err => Session -> IOC (Either err a) -> ExceptT Text IO a
runReadOnlyIOCE s act = do
    er <- lift $ runReadOnlyIOC s act
    case er of
        Left eMsg -> throwError . T.pack . show $ eMsg
        Right res -> return res

reportError :: Session -> SomeException -> IO a
reportError s err = do
    atomically $ writeTQueue (s ^. sessionMsgs) (TXS_CORE_SYSTEM_ERROR (show err))
    error (show err)
