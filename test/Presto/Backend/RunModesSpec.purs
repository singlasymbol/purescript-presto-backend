module Presto.Backend.RunModesSpec where

import Prelude
import Presto.Backend.Language.Types.EitherEx
import Presto.Backend.TestData.Common
import Presto.Backend.TestData.DBModel

import Control.Monad.Aff (Aff)
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (error)
import Control.Monad.Eff.Ref (REF, Ref, newRef, readRef, writeRef, modifyRef)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Except.Trans (runExceptT)
import Control.Monad.Reader.Trans (runReaderT)
import Control.Monad.State.Trans (runStateT)
import Data.Array (length, index)
import Data.Either (Either(..), isLeft, isRight)
import Data.Foreign (toForeign)
import Data.Foreign.Class (class Encode, class Decode, encode, decode)
import Data.Foreign.Generic (defaultOptions, genericDecode, genericDecodeJSON, genericEncode, genericEncodeJSON, encodeJSON, decodeJSON)
import Data.Foreign.Generic.Class (class GenericDecode, class GenericEncode)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Eq as GEq
import Data.Generic.Rep.Ord as GOrd
import Data.Generic.Rep.Show as GShow
import Data.Map as Map
import Data.Maybe (Maybe(..), isJust)
import Data.Options (Options(..), (:=))
import Data.StrMap as StrMap
import Data.Tuple (Tuple(..))
import Data.Tuple.Nested ((/\))
import Debug.Trace (spy)
import Presto.Backend.APIHandler (callAPI')
import Presto.Backend.Flow (BackendFlow, log, callAPI, runSysCmd, doAffRR, findOne, getDBConn)
import Presto.Backend.Language.Types.DB (SqlConn(..), MockedSqlConn(..), SequelizeConn(..))
import Presto.Backend.Playback.Entries (CallAPIEntry(..), DoAffEntry(..), LogEntry(..), RunDBEntry(..), RunSysCmdEntry(..))
import Presto.Backend.Playback.Types (EntryReplayingMode(..), PlaybackError(..), PlaybackErrorType(..), RecordingEntry(..))
import Presto.Backend.Runtime.Interpreter (runBackend)
import Presto.Backend.Runtime.Types (Connection(..), BackendRuntime(..), RunningMode(..))
import Presto.Backend.Types.API (class RestEndpoint, APIResult, Request(..), Headers(..), Response(..), ErrorPayload(..), Method(..), defaultDecodeResponse)
import Presto.Core.Utils.Encoding (defaultEncode, defaultDecode)
import Sequelize.Class (class Model, modelCols)
import Sequelize.Types (Conn, Instance, SEQUELIZE)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

data SomeRequest = SomeRequest
  { code   :: Int
  , number :: Number
  }

data SomeResponse = SomeResponse
  { code      :: Int
  , string :: String
  }

derive instance genericSomeRequest :: Generic SomeRequest _
derive instance eqSomeRequest      :: Eq      SomeRequest
instance showSomeRequest           :: Show    SomeRequest where show   = GShow.genericShow
instance decodeSomeRequest         :: Decode  SomeRequest where decode = defaultDecode
instance encodeSomeRequest         :: Encode  SomeRequest where encode = defaultEncode

derive instance genericSomeResponse :: Generic SomeResponse _
derive instance eqSomeResponse      :: Eq      SomeResponse
instance showSomeResponse           :: Show    SomeResponse where show   = GShow.genericShow
instance decodeSomeResponse         :: Decode  SomeResponse where decode = defaultDecode
instance encodeSomeResponse         :: Encode  SomeResponse where encode = defaultEncode

instance someRestEndpoint :: RestEndpoint SomeRequest SomeResponse where
  makeRequest r@(SomeRequest req) h = Request
    { method : GET
    , url : show req.code
    , payload : encodeJSON r
    , headers : h
    }
  -- You can spy the values going through the function:
  -- decodeResponse resp = const (defaultDecodeResponse resp) $ spy resp
  decodeResponse = defaultDecodeResponse

logRunner :: forall a. String -> a -> Aff _ Unit
logRunner tag value = pure (spy tag) *> pure (spy value) *> pure unit

failingLogRunner :: forall a. String -> a -> Aff _ Unit
failingLogRunner tag value = throwError $ error "Logger should not be called."

failingApiRunner :: forall e. Request -> Aff e String
failingApiRunner _ = throwError $ error "API Runner should not be called."

-- TODO: lazy?
failingAffRunner :: forall a. Aff _ a -> Aff _ a
failingAffRunner _ = throwError $ error "Aff Runner should not be called."

apiRunner :: forall e. Request -> Aff e String
apiRunner r@(Request req)
  | req.url == "1" = pure $ encodeJSON $ SomeResponse { code: 1, string: "Hello there!" }
apiRunner r
  | true = pure $ encodeJSON $  Response
    { code: 400
    , status: "Unknown request: " <> encodeJSON r
    , response: ErrorPayload
        { error: true
        , errorMessage: "Unknown request: " <> encodeJSON r
        , userMessage: "Unknown request"
        }
    }

-- TODO: lazy?
affRunner :: forall a. Aff _ a -> Aff _ a
affRunner aff = aff

emptyHeaders :: Headers
emptyHeaders = Headers []

logScript :: BackendFlow Unit Unit Unit
logScript = do
  log "logging1" "try1"
  log "logging2" "try2"

logScript' :: BackendFlow Unit Unit Unit
logScript' = do
  log "logging1.1" "try3 is hitting actual LogRunner"
  log "logging2.1" "try4 is hitting actual LogRunner"

callAPIScript :: BackendFlow Unit Unit (Tuple (APIResult SomeResponse) (APIResult SomeResponse))
callAPIScript = do
  eRes1 <- callAPI emptyHeaders $ SomeRequest { code: 1, number: 1.0 }
  eRes2 <- callAPI emptyHeaders $ SomeRequest { code: 2, number: 2.0 }
  pure $ Tuple eRes1 eRes2

callAPIScript' :: BackendFlow Unit Unit (Tuple (APIResult SomeResponse) (APIResult SomeResponse))
callAPIScript' = do
  eRes1 <- callAPI emptyHeaders $ SomeRequest { code: 1, number: 3.0 }
  eRes2 <- callAPI emptyHeaders $ SomeRequest { code: 2, number: 4.0 }
  pure $ Tuple eRes1 eRes2

logAndCallAPIScript :: BackendFlow Unit Unit (Tuple (APIResult SomeResponse) (APIResult SomeResponse))
logAndCallAPIScript = do
  logScript
  callAPIScript

logAndCallAPIScript' :: BackendFlow Unit Unit (Tuple (APIResult SomeResponse) (APIResult SomeResponse))
logAndCallAPIScript' = do
  logScript'
  callAPIScript'

runSysCmdScript :: BackendFlow Unit Unit String
runSysCmdScript = runSysCmd "echo 'ABC'"

runSysCmdScript' :: BackendFlow Unit Unit String
runSysCmdScript' = runSysCmd "echo 'DEF'"

doAffScript :: BackendFlow Unit Unit String
doAffScript = doAffRR (pure "This is result.")

doAffScript' :: BackendFlow Unit Unit String
doAffScript' = doAffRR (pure "This is result 2.")

callAllScript :: BackendFlow Unit Unit (Tuple (APIResult SomeResponse) (APIResult SomeResponse))
callAllScript = do
  logScript
  _ <- runSysCmdScript
  _ <- doAffScript
  callAPIScript

callAllScript' :: BackendFlow Unit Unit (Tuple (APIResult SomeResponse) (APIResult SomeResponse))
callAllScript' = do
  logScript'
  _ <- runSysCmdScript'
  _ <- doAffScript'
  callAPIScript'


testDB :: String
testDB = "TestDB"

dbScript0 :: BackendFlow Unit Unit SqlConn
dbScript0 = getDBConn testDB

dbScript1 :: BackendFlow Unit Unit (Maybe Car)
dbScript1 = do
  let carOpts = Options [ "model" /\ (toForeign "testModel") ]
  eMbCar <- findOne testDB carOpts
  case eMbCar of
    Left err    -> do
      log "Error" err
      pure Nothing
    Right Nothing -> do
      log "Not found" "car"
      pure Nothing
    Right (Just car) -> do
      log "Found a car" car
      pure $ Just car

runTests :: Spec _ Unit
runTests = do
  let backendRuntime mode = BackendRuntime
        { apiRunner   : apiRunner
        , connections : StrMap.empty
        , logRunner   : logRunner
        , affRunner   : affRunner
        , mode        : mode
        }
  let backendRuntimeRegular = backendRuntime RegularMode

  describe "Regular mode tests" do
    it "Log regular mode test" $ do
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRegular logScript) unit) unit)
      case eResult of
        Left err -> fail $ show err
        Right _  -> pure unit

    it "CallAPI regular mode test" $ do
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRegular callAPIScript) unit) unit)
      case eResult of
        Left err -> fail $ show err
        Right (Tuple (Tuple eRes1 eRes2) _) -> do
          isRight eRes1 `shouldEqual` true    -- TODO: check particular results
          isRight eRes2 `shouldEqual` false   -- TODO: check particular results
--How we will change the entry mode of any entry from Normal to any other mode
--Some problem is there with no Mock in Entry mode
  describe "Recording/replaying mode tests" do
    it "Record test" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      case eResult of
        Left err -> fail $ show err
        Right _  -> do
          recording <- liftEff $ readRef recordingRef
          length recording.entries `shouldEqual` 4
          index recording.entries 0 `shouldEqual` (Just $ RecordingEntry Normal "{\"tag\":\"logging1\",\"message\":\"\\\"try1\\\"\"}" )
          index recording.entries 1 `shouldEqual` (Just $ RecordingEntry  Normal "{\"tag\":\"logging2\",\"message\":\"\\\"try2\\\"\"}")
          index recording.entries 2 `shouldEqual` (Just $ RecordingEntry Normal  "{\"jsonResult\":{\"contents\":\"{\\\"string\\\":\\\"Hello there!\\\",\\\"code\\\":1}\",\"tag\":\"RightEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"1\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":1,\\\\\\\"code\\\\\\\":1}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
            )
          index recording.entries 3 `shouldEqual` (Just $ RecordingEntry Normal "{\"jsonResult\":{\"contents\":{\"status\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"response\":{\"userMessage\":\"Unknown request\",\"errorMessage\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"error\":true},\"code\":400},\"tag\":\"LeftEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
             )

    it "Record / replay test: log and callAPI success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      --eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRegular   callAPIScript') unit) unit)
      isRight eResult `shouldEqual` true

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : [""]
              , disableMocking : [""]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript) unit) unit)
      curStep  <- liftEff $ readRef stepRef
      isRight eResult2 `shouldEqual` true
      curStep `shouldEqual` 4

    it "Record / replay test: index out of range" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef, disableEntries : [""] }
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      isRight eResult `shouldEqual` true

      stepRef   <- liftEff $ newRef 10
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : []
              , disableMocking : [""]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript) unit) unit)
      curStep  <- liftEff $ readRef stepRef
      pbError  <- liftEff $ readRef errorRef
      isRight eResult2 `shouldEqual` false
      pbError `shouldEqual` (Just $ PlaybackError
        { errorMessage: "Expected: LogEntry"
        , errorType: UnexpectedRecordingEnd
        })
      curStep `shouldEqual` 10

    it "Record / replay test: started from the middle" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef, disableEntries : [""] }
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      isRight eResult `shouldEqual` true

      stepRef   <- liftEff $ newRef 2
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : []
              , disableMocking : []
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript) unit) unit)
      curStep  <- liftEff $ readRef stepRef
      pbError  <- liftEff $ readRef errorRef
      isRight eResult2 `shouldEqual` false
      pbError `shouldEqual` (Just $ PlaybackError { errorMessage: "Expected: LogEntry", errorType: UnknownRRItem })
      curStep `shouldEqual` 3

    it "Record / replay test: runSysCmd success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording runSysCmdScript) unit) unit)
      case eResult of
        Right (Tuple n unit) -> n `shouldEqual` "ABC\n"
        _ -> fail $ show eResult

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : []
              , disableMocking : []
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime runSysCmdScript) unit) unit)
      curStep  <- liftEff $ readRef stepRef
      case eResult2 of
        Right (Tuple n unit) -> n `shouldEqual` "ABC\n"
        Left err -> fail $ show err
      curStep `shouldEqual` 1

    it "Record / replay test: doAff success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef ,  disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording doAffScript) unit) unit)
      case eResult of
        Right (Tuple n unit) -> n `shouldEqual` "This is result."
        _ -> fail $ show eResult

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : []
              , disableMocking : []
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime doAffScript) unit) unit)
      curStep  <- liftEff $ readRef stepRef
      case eResult2 of
        Right (Tuple n unit) -> n `shouldEqual` "This is result."
        Left err -> fail $ show err
      curStep `shouldEqual` 1

    it "Record / replay test: getDBConn success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let conns = StrMap.singleton testDB $ SqlConn $ MockedSql $ MockedSqlConn testDB
      let (BackendRuntime rt') = backendRuntime $ RecordingMode {recordingRef , disableEntries : []}
      let rt = BackendRuntime $ rt' { connections = conns }
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend rt dbScript0) unit) unit)
      case eResult of
        Right (Tuple (MockedSql (MockedSqlConn dbName)) unit) -> dbName `shouldEqual` testDB
        Left err -> fail $ show err
        _ -> fail "Unknown result"

  describe "Record/Replay Test in Global Config Mode" do
    it "Record Global Config test : disableEntries Log Success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : ["LogEntry"]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      case eResult of
        Left err -> fail $ show err
        Right _  -> do
          recording <- liftEff $ readRef recordingRef
          length recording.entries `shouldEqual` 2
          index recording.entries 0 `shouldEqual` (Just $ RecordingEntry Normal  "{\"jsonResult\":{\"contents\":\"{\\\"string\\\":\\\"Hello there!\\\",\\\"code\\\":1}\",\"tag\":\"RightEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"1\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":1,\\\\\\\"code\\\\\\\":1}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
            )
          index recording.entries 1 `shouldEqual` (Just $ RecordingEntry Normal "{\"jsonResult\":{\"contents\":{\"status\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"response\":{\"userMessage\":\"Unknown request\",\"errorMessage\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"error\":true},\"code\":400},\"tag\":\"LeftEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
             )
    it "Record Global Config test : disableEntries GetDBConn Success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let conns = StrMap.singleton testDB $ SqlConn $ MockedSql $ MockedSqlConn testDB
      let (BackendRuntime rt') = backendRuntime $ RecordingMode {recordingRef , disableEntries : ["GetDBConnEntry"]}
      let rt = BackendRuntime $ rt' { connections = conns }
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend rt dbScript0) unit) unit)
      case eResult of
        Right (Tuple (MockedSql (MockedSqlConn dbName)) unit) -> do
          dbName `shouldEqual` testDB
          recording <- liftEff $ readRef recordingRef
          length recording.entries `shouldEqual` 0
        Left err -> fail $ show err
        _ -> fail "Unknown result"
    it "Record Global Config test : disableEntries CallApi Success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : ["CallAPIEntry"]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      case eResult of
        Left err -> fail $ show err
        Right _  -> do
          recording <- liftEff $ readRef recordingRef
          length recording.entries `shouldEqual` 2
          index recording.entries 0 `shouldEqual` (Just $ RecordingEntry Normal "{\"tag\":\"logging1\",\"message\":\"\\\"try1\\\"\"}" )
          index recording.entries 1 `shouldEqual` (Just $ RecordingEntry  Normal "{\"tag\":\"logging2\",\"message\":\"\\\"try2\\\"\"}")

    it "Replay Global Config test : log and callAPI success with disableVerify" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      isRight eResult `shouldEqual` true

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : ["LogEntry","CallAPIEntry"]
              , disableMocking : [""]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript') unit) unit)
      --find way to show that the responses stored in eResult1 is same as of eResult2
      curStep  <- liftEff $ readRef stepRef
      isRight eResult2 `shouldEqual` true
      curStep `shouldEqual` 4
    it "Replay Global Config test : log and callAPI success with disableMocking" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording logAndCallAPIScript) unit) unit)
      isRight eResult `shouldEqual` true

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : apiRunner
            , connections : StrMap.empty
            , logRunner   : logRunner
            , affRunner   : affRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : [""]
              , disableMocking : ["LogEntry","CallAPIEntry"]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript') unit) unit)
      --find way to show that the responses stored in eResult1 is same as of eResult2
      curStep  <- liftEff $ readRef stepRef
      isRight eResult2 `shouldEqual` true
      curStep `shouldEqual` 4

    it "Replay Global config test: runSysCmd with disableVerify success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording runSysCmdScript) unit) unit)
      case eResult of
        Right (Tuple n unit) -> n `shouldEqual` "ABC\n"
        _ -> fail $ show eResult

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : ["RunSysCmdEntry"]
              , disableMocking : []
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime runSysCmdScript') unit) unit)
      curStep  <- liftEff $ readRef stepRef
      case eResult2 of
        Right (Tuple n unit) -> n `shouldEqual` "ABC\n"
        Left err -> fail $ show err
      curStep `shouldEqual` 1
    it "Replay Global config test: runSysCmd with disableMock success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef , disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording runSysCmdScript) unit) unit)
      case eResult of
        Right (Tuple n unit) -> n `shouldEqual` "ABC\n"
        _ -> fail $ show eResult

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : []
              , disableMocking : ["RunSysCmdEntry"]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime runSysCmdScript') unit) unit)
      curStep  <- liftEff $ readRef stepRef
      case eResult2 of
        Right (Tuple n unit) -> n `shouldEqual` "DEF\n"
        Left err -> fail $ show err
      curStep `shouldEqual` 1
    it "Replay Global Config test: doAff with disableVerify success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef ,  disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording doAffScript) unit) unit)
      case eResult of
        Right (Tuple n unit) -> n `shouldEqual` "This is result."
        _ -> fail $ show eResult

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : failingAffRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : ["DoAffEntry"]
              , disableMocking : []
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime doAffScript) unit) unit)
      curStep  <- liftEff $ readRef stepRef
      case eResult2 of
        Right (Tuple n unit) -> n `shouldEqual` "This is result."
        Left err -> fail $ show err
      curStep `shouldEqual` 1
    it "Replay Global Config test: doAff with disableMocking success" $ do
      recordingRef <- liftEff $ newRef { entries : [] }
      let backendRuntimeRecording = backendRuntime $ RecordingMode { recordingRef ,  disableEntries : [""]}
      eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend backendRuntimeRecording doAffScript) unit) unit)
      case eResult of
        Right (Tuple n unit) -> n `shouldEqual` "This is result."
        _ -> fail $ show eResult

      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : failingApiRunner
            , connections : StrMap.empty
            , logRunner   : failingLogRunner
            , affRunner   : affRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : []
              , disableMocking : ["DoAffEntry"]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime doAffScript') unit) unit)
      curStep  <- liftEff $ readRef stepRef
      case eResult2 of
        Right (Tuple n unit) -> n `shouldEqual` "This is result 2."
        Left err -> fail $ show err
      curStep `shouldEqual` 1
  describe "Record/Replay Test in Entry Config Mode" do
    it "Replay the entries in Normal entry Mode" $ do
      recordingRef <- liftEff $ newRef { entries :[ RecordingEntry Normal "{\"tag\":\"logging1\",\"message\":\"\\\"try1\\\"\"}"
                                                  , RecordingEntry  Normal "{\"tag\":\"logging2\",\"message\":\"\\\"try2\\\"\"}"
                                                  , RecordingEntry Normal  "{\"jsonResult\":{\"contents\":\"{\\\"string\\\":\\\"Hello there!\\\",\\\"code\\\":1}\",\"tag\":\"RightEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"1\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":1,\\\\\\\"code\\\\\\\":1}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
                                                  , RecordingEntry Normal "{\"jsonResult\":{\"contents\":{\"status\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"response\":{\"userMessage\":\"Unknown request\",\"errorMessage\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"error\":true},\"code\":400},\"tag\":\"LeftEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
                                                  ]}
      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : apiRunner
            , connections : StrMap.empty
            , logRunner   : logRunner
            , affRunner   : affRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : [""]
              , disableMocking : [""]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript) unit) unit)
      --find way to show that the responses stored in eResult1 is same as of eResult2
      curStep  <- liftEff $ readRef stepRef
      isRight eResult2 `shouldEqual` true
      curStep `shouldEqual` 4
    it "Replay the entries in NoVerify entry Mode" $ do
      recordingRef <- liftEff $ newRef { entries :[ RecordingEntry NoVerify "{\"tag\":\"logging1\",\"message\":\"\\\"try1\\\"\"}"
                                                  , RecordingEntry NoVerify "{\"tag\":\"logging2\",\"message\":\"\\\"try2\\\"\"}"
                                                  , RecordingEntry NoVerify  "{\"jsonResult\":{\"contents\":\"{\\\"string\\\":\\\"Hello there!\\\",\\\"code\\\":1}\",\"tag\":\"RightEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"1\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":1,\\\\\\\"code\\\\\\\":1}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
                                                  , RecordingEntry NoVerify "{\"jsonResult\":{\"contents\":{\"status\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"response\":{\"userMessage\":\"Unknown request\",\"errorMessage\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"error\":true},\"code\":400},\"tag\":\"LeftEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
                                                  ]}
      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : apiRunner
            , connections : StrMap.empty
            , logRunner   : logRunner
            , affRunner   : affRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : [""]
              , disableMocking : [""]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript') unit) unit)
      curStep  <- liftEff $ readRef stepRef
      isRight eResult2 `shouldEqual` true
      curStep `shouldEqual` 4
    it "Replay the entries in NoMock entry Mode" $ do
      recordingRef <- liftEff $ newRef { entries :[ RecordingEntry NoMock "{\"tag\":\"logging1\",\"message\":\"\\\"try1\\\"\"}"
                                                  , RecordingEntry NoMock "{\"tag\":\"logging2\",\"message\":\"\\\"try2\\\"\"}"
                                                  , RecordingEntry NoMock  "{\"jsonResult\":{\"contents\":\"{\\\"string\\\":\\\"Hello there!\\\",\\\"code\\\":1}\",\"tag\":\"RightEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"1\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":1,\\\\\\\"code\\\\\\\":1}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
                                                  , RecordingEntry NoMock "{\"jsonResult\":{\"contents\":{\"status\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"response\":{\"userMessage\":\"Unknown request\",\"errorMessage\":\"Unknown request: {\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\",\"error\":true},\"code\":400},\"tag\":\"LeftEx\"},\"jsonRequest\":\"{\\\"url\\\":\\\"2\\\",\\\"payload\\\":\\\"{\\\\\\\"number\\\\\\\":2,\\\\\\\"code\\\\\\\":2}\\\",\\\"method\\\":{\\\"tag\\\":\\\"GET\\\"},\\\"headers\\\":[]}\"}"
                                                  ]}
      stepRef   <- liftEff $ newRef 0
      errorRef  <- liftEff $ newRef Nothing
      recording <- liftEff $ readRef recordingRef
      let replayingBackendRuntime = BackendRuntime
            { apiRunner   : apiRunner
            , connections : StrMap.empty
            , logRunner   : logRunner
            , affRunner   : affRunner
            , mode        : ReplayingMode
              { recording
              , stepRef
              , errorRef
              , disableVerify : [""]
              , disableMocking : [""]
              }
            }
      eResult2 <- liftAff $ runExceptT (runStateT (runReaderT (runBackend replayingBackendRuntime logAndCallAPIScript') unit) unit)
      curStep  <- liftEff $ readRef stepRef
      isRight eResult2 `shouldEqual` true
      curStep `shouldEqual` 4


    --
    -- it "Record / replay test: db success test1" $ do
    --   recordingRef <- liftEff $ newRef { entries : [] }
    --   let conns = StrMap.singleton testDB $ SqlConn $ MockedSql $ MockedSqlConn testDB
    --   let (BackendRuntime rt') = backendRuntime $ RecordingMode { recordingRef }
    --   let rt = BackendRuntime $ rt' { connections = conns }
    --   eResult <- liftAff $ runExceptT (runStateT (runReaderT (runBackend rt dbScript1) unit) unit)
    --   case eResult of
    --     Right (Tuple (MockedSql (MockedSqlConn dbName)) unit) -> dbName `shouldEqual` testDB
    --     Left err -> fail $ show err
    --     _ -> fail "Unknown result"
