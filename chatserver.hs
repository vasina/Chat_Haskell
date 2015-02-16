-- for record wildcard pattern (like Client{..})
-- which brings into scope all the fields of the Client record 
{-# LANGUAGE RecordWildCards #-} 

import Prelude hiding (id)

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Network
import System.IO
import Text.Printf
import System.IO.Error
import qualified Data.Map as Map

type ClientName = String

--The per-client state 

data Client = Client
  { clientID       :: TVar (Integer) 
  , clientName     :: ClientName
  , clientHandle   :: Handle
  -- TVar indicating whether this client has been kicked
  -- contains Nothing or Just s, s - reason for kicking
  , clientKicked   :: TVar (Maybe String)
  --The TChan clientSendChan carries all the other messages 
  --that may be sent to a client
  , clientSendChan :: TChan Message
  }

-- there are all the messages that client can get
  
data Message = Notice String --a message from the server
             | Tell String ClientName String --a private message from another client
             | Broadcast ClientName String --a public message from another client
             | Command String -- a line of text received from the user himself

--a way to construct a new instance of Client

newClient :: Integer -> ClientName -> Handle -> STM Client
newClient n name handle = do
  id <- newTVar n -- create new box for ID
  c <- newTChan -- create new channel 
  k <- newTVar Nothing --create new box for reason
  return Client { clientID       = id
                , clientName     = name -- name we get from user
                , clientHandle   = handle --handle we get from user
                , clientSendChan = c
                , clientKicked   = k
                }

-- function for sending a Message to a given Client
				
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg =
  writeTChan clientSendChan msg

-- put reason in the box for reason of kicking

writeReason :: Client -> String -> STM()
writeReason Client{..} reason =
     writeTVar clientKicked $ Just reason
   
-- function for kicking client
						  
kickClient :: Server -> Client -> ClientName -> String -> STM ()
kickClient Server{..} clientik@Client{..} name reason = do
     -- get set of clients and write reason for client or error for sender
        clientmap <- readTVar clients 
        case Map.lookup name clientmap of
             Nothing -> sendMessage clientik $ Notice "Nonexistent user"
             Just client -> writeReason client reason

-- function for sending a private message
		
tell :: Server -> Client -> ClientName -> Message -> STM ()
tell Server{..} clientik@Client{..} name msg = do
        clientmap <- readTVar clients --get set of clients
-- if there is no client in set notice sender about it
-- else send message to receiver
        case Map.lookup name clientmap of
             Nothing -> sendMessage clientik $ Notice "Nonexistent user"
             Just client -> do 
                 sendMessage client msg
                 sendMessage clientik msg

-- check clients' ID for kick operation
				 
checkID :: Server -> Client -> ClientName -> String -> STM ()
checkID server@Server{..} client@Client{..} name reason = do
        id <- readTVar clientID 
        if (id == 0) 
             then kickClient server client name reason
             else sendMessage client $ Notice "Illegal operation! You are not a super user"

-- server is just a TVar containing a mapping from ClientName to Client
			 
data Server = Server
  { clients :: TVar (Map.Map ClientName Client)
  }

--create new server means create new TVar with empty dictionary
  
newServer :: IO Server
newServer = do
  c <- newTVarIO Map.empty
  return Server { clients = c }

--broadcast a Message to all the clients means 
--send message(write to channel) to each client from dictionary
  
broadcast :: Server -> Message -> STM ()
broadcast Server{..} msg = do
  clientmap <- readTVar clients
  mapM_ (\client -> sendMessage client msg) (Map.elems clientmap)

--main function   
  
main :: IO ()
main = withSocketsDo $ do
  -- create new server
  server <- newServer
  -- create a network socket to listen on port 44444
  sock <- listenOn (PortNumber (fromIntegral port))
  printf "Listening on port %d\n" port
  -- enter a loop to accept connections from clients
  let mainLoop n = do
      -- waits for a new client connection
	  -- returns Handle and some information about client
      (handle, host, port) <- accept sock
      printf "Accepted connection from %s: %s\n" host (show port)
	  --create a new thread to handle the request
      --forkFinally let us to ensure that the Handle is always closed 
	  --in the event of an exception in the server thread	  
      forkFinally (talk n handle server) (\_ -> hClose handle)
      mainLoop $! n+1
   in mainLoop 0

port :: Int
port = 44444

--The client must choose a name that is not currently in use

checkAddClient :: Integer -> Server -> ClientName -> Handle -> IO (Maybe Client)
checkAddClient n server@Server{..} name handle = atomically $ do
  --take dictionary of clients from box
  clientmap <- readTVar clients
  --if name is currently in use, client will not be created
  if Map.member name clientmap
    then return Nothing
  --if not - create new client
    else do client <- newClient n name handle
  --renew dictionary of clients and notify all clients about new one
            writeTVar clients $ Map.insert name client clientmap
            broadcast server  $ Notice (name ++ " has connected")
            return (Just client)

-- renew ID, if somebody disconnects 
			
renewID :: Client -> STM ()
renewID Client{..} = do
            id <- readTVar clientID
            writeTVar clientID $ id - 1
			
-- handling disconnection of client
			
removeClient :: Server -> ClientName -> IO ()
removeClient server@Server{..} name = atomically $ do
  modifyTVar' clients $ Map.delete name
  clientmap <- readTVar clients
  mapM_ (\client -> renewID client) (Map.elems clientmap)
  broadcast server $ Notice (name ++ " has disconnected")
  
-- create and run new client
  
talk :: Integer -> Handle -> Server -> IO ()
talk n handle server@Server{..} = do
  hSetNewlineMode handle universalNewlineMode
  -- set the buffering mode for the Handle to line buffering
  hSetBuffering handle LineBuffering
  readName
 where
   readName = do
   --When a client connects,the server requests
   --the name that the client will be using
    hPutStrLn handle " "
    hPutStrLn handle "What is your name?"
    hPutStrLn handle " "
    name <- hGetLine handle
	--if null ask again
    if null name
      then readName
-- mask asynchronous exceptions to eliminate the possibility
-- that an exception is received just after checkAddClient but before runClient
      else mask $ \restore -> do
             ok <- checkAddClient n server name handle --check name
             case ok of
               Nothing -> restore $ do --restore them again
			   --name is in use, choose another one
                 hPutStrLn handle " "
                 hPrintf handle "The name %s is in use, please choose another\n " name
                 readName
			   --run new client, ensuring that the Client will be removed 
			   --when it disconnects or any failure occurs
               Just client ->
			   --unmask asynchronous exceptions when calling runClient 
                  restore (runClient server client)
                      `finally` removeClient server name

--------------------------------------------------------------------

-- implementation of race function

data Async a = Async ThreadId (TMVar (Either SomeException a))

async :: IO a -> IO (Async a)
async action = do
  var <- newEmptyTMVarIO
  t <- forkFinally action (atomically . putTMVar var)
  return (Async t var)

waitCatchSTM :: Async a -> STM (Either SomeException a)
waitCatchSTM (Async _ var) = readTMVar var

waitSTM :: Async a -> STM a
waitSTM a = do
  r <- waitCatchSTM a
  case r of
    Left e  -> throwSTM e
    Right a -> return a

waitEither :: Async a -> Async b -> IO (Either a b)
waitEither a b = atomically $
  fmap Left (waitSTM a)
    `orElse`
  fmap Right (waitSTM b)

cancel :: Async a -> IO ()
cancel (Async t var) = throwTo t ThreadKilled

withAsync :: IO a -> (Async a -> IO b) -> IO b
withAsync io operation = bracket (async io) cancel operation

race :: IO a -> IO b -> IO (Either a b)
race ioa iob =
  withAsync ioa $ \a ->
  withAsync iob $ \b ->
    waitEither a b
-------------------------------------------------------------------

--The main functionality of the client

runClient :: Server -> Client -> IO ()
runClient serv@Server{..} client@Client{..} = do
   hPutStrLn clientHandle " "
   hPutStrLn clientHandle "Welcome! Write /help to get useful information"
   hPutStrLn clientHandle " "
--race to create the two threads with a sibling relationship 
--so that if either thread returns or fails, the other will be cancelled
   race server receive
   return ()
 where
--a receive thread to forward the network input into a TChan
  receive = forever $ do
-- we read one line at a time from the client’s Handle 
-- and forward it to the server thread as a Command message
    msg <- hGetLine clientHandle
    atomically $ sendMessage client (Command msg)
-- a server thread to wait for the different kinds of events
-- and act upon them
  server = join $ atomically $ do
  -- check being kicked by another client
    k <- readTVar clientKicked
    case k of
      Just reason -> return $
	  --notice client and disconnected him
        hPutStrLn clientHandle $ "*** You have been kicked: " ++ reason
      Nothing -> do
	  -- take message from channel and act upon it
        msg <- readTChan clientSendChan
        return $ do
            continue <- handleMessage serv client msg
            when continue $ server

-- The handleMessage function acts on a message			
			
handleMessage :: Server -> Client -> Message -> IO Bool
handleMessage server client@Client{..} message =
  case message of
     -- output clients' connecting or disconnecting message
     Notice msg         -> nOutput msg
	 -- output /tell messages
     Tell recipient sender msg      -> tOutput recipient sender msg  
	 -- output broadcasts from other clients
     Broadcast sender msg -> bOutput sender msg 
	 -- implement commands from client himself
     Command msg ->
       case words msg of
	        -- kick somebody
           "/kick" : who : why -> do
               atomically $ checkID server client who (unwords why)
               hPutStrLn clientHandle " "
               return True
			-- sent private message
           "/tell" : who : what -> do
               atomically $ tell server client who $ Tell who clientName (unwords what)
               hPutStrLn clientHandle " "
               return True
			-- get information about the possible actions 
           ["/help"] -> do
               hPutStrLn clientHandle " "
               hPutStrLn clientHandle "/tell name message - Sends message to the user name" 
               hPutStrLn clientHandle "/kick name reason  - Disconnects user name, specifying the reason, if you are a super user"
               hPutStrLn clientHandle "/help              - Shows information about the possible actions "
               hPutStrLn clientHandle "/quit              - Disconnects the current client"
               hPutStrLn clientHandle "message            - Sends message to all the connected clients."
               hPutStrLn clientHandle " "
               return True		   
			-- exit
           ["/quit"] ->
               return False
			-- do unrecognised command
           ('/':_):_ -> do
               atomically $ sendMessage client $ Notice $ "Unrecognised command: " ++ msg
               hPutStrLn clientHandle " "
               return True
			-- sent message to all clients
           _ -> do
               atomically $ broadcast server $ Broadcast clientName msg
               return True
 where
 -- output functions
   nOutput msg = do 
              hPutStrLn clientHandle $ "*** " ++ msg
              hPutStrLn clientHandle " "
              return True
   tOutput recipient sender msg = if (sender == clientName)
                      then do 
                           hPutStrLn clientHandle $ "*" ++ "You " ++ "to " ++ recipient ++ "*: " ++ msg
                           hPutStrLn clientHandle " "
                           return True	 
                      else do 
                           hPutStrLn clientHandle $ "*" ++ sender ++ "*: " ++ msg
                           hPutStrLn clientHandle " "
                           return True	 					  
   bOutput sender msg = if (sender == clientName)
                      then do 
                           hPutStrLn clientHandle " " 
                           hPutStrLn clientHandle $ "<You>: " ++ msg
                           hPutStrLn clientHandle " "
                           return True
                      else do 
                           hPutStrLn clientHandle $ "<" ++ sender ++ ">: " ++ msg
                           hPutStrLn clientHandle " "
                           return True		 