{-# LANGUAGE OverloadedStrings #-}

module Network.WebSockets.Sync where

import           Control.Monad

import           Control.Concurrent
import           Control.Concurrent.Async
import           Control.Concurrent.Chan
import           Control.Concurrent.STM
import           Control.Exception

import           Data.Aeson
import           Data.Aeson.Types

import           Data.Hashable
import           Data.Maybe

import qualified Data.ByteString.Lazy           as B
import qualified Data.Text                      as T

import qualified Network.WebSockets             as WS

data Request a = SyncRequest T.Text a
               | AsyncRequest a

data Response a = SyncResponse T.Text a
                | SyncError T.Text T.Text
                | AsyncMessage a

instance FromJSON a => FromJSON (Request a) where
  parseJSON (Object o) = do
    rtype <- o .: "cmd"
    parse (rtype :: T.Text)

    where parse "sync-request"  = SyncRequest  <$> o .: "rid" <*> o .: "request"
          parse "async-request" = AsyncRequest <$> o .: "request"

  parseJSON _          = fail "Could not parse request"

instance ToJSON a => ToJSON (Response a) where
  toJSON (SyncResponse rid msg) = object
    [ "cmd" .= ("sync-response" :: T.Text)
    , "rid" .= rid
    , "response" .= msg
    ]
  toJSON (SyncError rid e) = object
    [ "cmd" .= ("sync-response" :: T.Text)
    , "rid" .= rid
    , "error" .= e
    ]
  toJSON (AsyncMessage a) = object
    [ "cmd" .= ("async-message" :: T.Text)
    , "message" .= a
    ]

data Session sid uid user msg = Session
  { sessionId :: sid
  , sessionUserId :: uid
  , sessionUser :: user
  , sessionQueue :: TQueue (Response msg)
  }

instance Eq sid => Eq (Session sid uid user msg) where
  s1 == s2 = sessionId s1 == sessionId s2

withMessage :: FromJSON msg => WS.DataMessage -> (msg -> IO ()) -> IO ()
withMessage (WS.Text msg) action = case eitherDecode msg of
  Right msg -> action msg
  Left error -> putStrLn $ "Could not parse message: " ++ show error
withMessage msg _ = putStrLn $ "Could not parse message: " ++ show msg

runConnection :: (ToJSON msgout, FromJSON msgin)
              => WS.Connection                         -- connection
              -> TQueue (Response msgout)              -- session queue
              -> IO b                                  -- close action
              -> (msgin -> IO (Either T.Text msgout))  -- sync action
              -> (msgin -> IO ())                      -- async action
              -> IO ()
runConnection conn tq close sync async = do
  -- FIXME: heartbeat
  let read = forever $ do
        msg <- WS.receiveDataMessage conn
        putStrLn $ "Received message " ++ show msg

        withMessage msg $ \req -> case req of
          SyncRequest rid req -> do
            r <- sync req
            case r of
              Right v -> atomically $ writeTQueue tq $ SyncResponse rid v
              Left e ->  atomically $ writeTQueue tq $ SyncError rid e
          AsyncRequest req -> async req

      write = forever $ do
        msg <- atomically $ readTQueue tq
        -- FIXME: remove
        -- threadDelay $ 1 * 10^6 `div` 2
        putStrLn $ "Sending message " ++ show (encode msg)
        WS.send conn (WS.DataMessage $ WS.Text $ encode msg)

  void $ finally (race read write) close

syncRespond :: Session sid uid user msg -> Request b -> msg -> IO ()
syncRespond session (SyncRequest rid _) res = do
  atomically $ writeTQueue (sessionQueue session) (SyncResponse rid res)
syncRespond session _ res = return ()

runSyncServer :: (FromJSON msgin, ToJSON msgout) => Int -> (msgin -> IO msgout) -> IO ()
runSyncServer port f = do
  WS.runServer "0.0.0.0" port $ \req -> do
    conn <- WS.acceptRequest req

    void $ forkIO $ flip finally (return ()) $ do
      msg <- WS.receiveDataMessage conn
      withMessage msg $ \msgin -> do
        msgout <- f msgin
        WS.send conn (WS.DataMessage $ WS.Text $ encode msgout)
