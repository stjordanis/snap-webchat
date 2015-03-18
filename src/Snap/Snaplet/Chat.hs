{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-|
Module      : Chat
Description : Chat module for Snap Framework
Author      : Dennis J. McWherter, Jr.
Maintainer  : dennis@deathbytape.com
Stability   : experimental
Portability : POSIX

Chat Snaplet used in example tutorial.
-}
module Snap.Snaplet.Chat(
  Chat(..)
  ,initChat
  ) where

import Control.Concurrent.Async
import Control.Concurrent.Chan
import Control.Exception (catch)
import Control.Monad.IO.Class
import Control.Monad.State.Class
import Data.ByteString
import qualified Data.ByteString.Lazy.Char8 as C
import qualified Data.ByteString.Lazy as LBS
import Data.IORef
import Data.Profunctor.Product.TH (makeAdaptorAndInstance)
import Data.Text.Encoding
import Data.Text.Read
import Network.WebSockets
import Network.WebSockets.Snap
import Opaleye
import Snap.Core
import Snap.Snaplet
import Snap.Snaplet.Auth

type UserIdentity = (LBS.ByteString, Int)
type BroadcastChannel = (Chan LBS.ByteString)
data Chat = Chat { bcastChan :: BroadcastChannel -- ^ Broadcast channel
                 , userCount :: IORef Int -- ^ Current user count
                 }
data ChatMessage' a b c d = ChatMessage' { msgId :: a -- ^ Unique identifier for message
                                         , msgText :: b -- ^ Message text
                                         , msgUserId :: c -- ^ User id of poster
                                         , msgDate :: d -- ^ Date message was posted
                                         } deriving (Show)
type ChatMessage = ChatMessage' Int String Int String
type ChatColumnW = ChatMessage' (Maybe (Column PGInt4)) (Column PGText) (Column PGInt4) (Maybe (Column PGTimestamptz))
type ChatColumnR = ChatMessage' (Column PGInt4) (Column PGText) (Column PGInt4) (Column PGTimestamptz)

-- Generate profunctor
$(makeAdaptorAndInstance "pChatMessage" ''ChatMessage')

-- | Table definition for chat messages
chatMessageTable :: Table ChatColumnW ChatColumnR
chatMessageTable = Table "chat"
                   (pChatMessage ChatMessage' { msgId = optional "id"
                                              , msgText = required "message"
                                              , msgUserId = required "user_id"
                                              , msgDate = optional "date"
                                              })

-- | Websocket server for real-time chat communication
chatServer :: UserIdentity -> Handler b Chat ()
chatServer (user, uid) = do
  bchan <- gets bcastChan
  cntRef <- gets userCount
  liftIO $ incCount cntRef
  runWebSocketsSnap $ (flip catch) (handleQuit cntRef) . handler bchan
  where -- Helper to accept client connection request and setup serving loop
        handler :: BroadcastChannel -> ServerApp
        handler chan pconn = do
          conn <- acceptRequest pconn
          dup <- dupChan chan
          forkPingThread conn 15 -- Check that our user is alive every 15 seconds
          reader <- async $ readChan dup
          writer <- async $ receiveDataMessage conn
          serve conn dup reader writer
        -- Helper to actually manages comms among users
        serve :: Connection -> BroadcastChannel -> Async LBS.ByteString -> Async DataMessage -> IO ()
        serve conn chan reader writer = do
          result <- waitEither reader writer
          case result of
           Left msg -> sendDataMessage conn $ Text msg
           Right (Text msg) -> logMessage msg >> writeChan chan (LBS.append "<" $ LBS.append user $ LBS.append "> " msg)
           Right _ -> Prelude.putStrLn "Received some binary data from client. Ignoring."
          -- NOTE: This is ugly.. It continuously creates/tearsdown threads
          -- Determine who won the race and which async we need to restart
          let loop = serve conn chan
          case result of
           Left _ -> do
             nextReader <- async $ readChan chan
             loop nextReader writer
           Right _ -> do
             nextWriter <- async $ receiveDataMessage conn
             loop reader nextWriter
        -- Helper to handle when user quits
        handleQuit :: IORef Int -> ConnectionException -> IO ()
        handleQuit cntRef (CloseRequest _ _) = decCount cntRef
        handleQuit cntRef ConnectionClosed = decCount cntRef
        handleQuit _ e = Prelude.putStrLn $ "Unhandled exception: " ++ show e
        -- Helpers for modifying user count
        updateCount :: IORef Int -> (Int -> (Int, Int)) -> IO ()
        updateCount cntRef fn = atomicModifyIORef cntRef fn >>= Prelude.putStrLn . ("User count: " ++) . show
        decCount cntRef = updateCount cntRef (\x -> let y = x - 1 in (y, y))
        incCount cntRef = updateCount cntRef (\x -> let y = x + 1 in (y, y))
        -- Database helper
        logMessage msg =
          Prelude.putStrLn $ arrangeInsertSql chatMessageTable $
            ChatMessage' { msgId = Nothing
                         , msgText = (pgString . C.unpack) msg
                         , msgUserId = pgInt4 uid
                         , msgDate = Nothing
                         }

-- | Handler responsible for displaying main chat page
pageHandler :: Handler b Chat ()
pageHandler = writeText "Send user to chat page."

-- | Handler to retrieve the last 50 chat messages
getLastFifty :: Handler b Chat ()
getLastFifty = do
  liftIO $ Prelude.putStrLn $ getMessages ((limit 50 . orderBy (desc msgDate) . queryTable) chatMessageTable)
  where getMessages :: Query ChatColumnR -> String
        getMessages = showSqlForPostgres

-- | Routes protected by login
routes :: SnapletLens b (AuthManager b) -> [(ByteString, Handler b Chat ())]
routes auth = (fmap $ enforceLogin auth)
         [ ("/", pageHandler)
         , ("/chat", handleChatClient)
         , ("/last", getLastFifty)]
  where handleChatClient = do
          user <- withTop auth $ do
            cur <- currentUser
            return $ case cur of
                      Just u ->
                        case userId u of
                         Just uid -> case (decimal . unUid) uid of
                           Right idVal -> Just (textToLBS $ userLogin u, fst idVal)
                           Left _ -> Nothing
                         Nothing -> Nothing
                      Nothing -> Nothing
          maybe (return ()) chatServer user
        textToLBS = LBS.pack . unpack . encodeUtf8
               
-- | Initialize snaplet by providing a snaplet containing an active
-- database connection.
initChat :: SnapletLens b (AuthManager b) -- ^ Auth manager
         -> SnapletInit b Chat
initChat auth = makeSnaplet "chat" "web chat backend" Nothing $ do
    addRoutes $ routes auth
    cnt <- liftIO $ newIORef 0
    chan <- liftIO $ newChan
    return $! Chat chan cnt

enforceLogin :: SnapletLens b (AuthManager b)
             -> (ByteString, Handler b v ())
             -> (ByteString, Handler b v ())
enforceLogin auth (uri, handler) = (uri, requireUser auth badLogin handler)
  where badLogin = do
          modifyResponse $ setResponseCode 401
          writeBS "Please login to access any chat features."

