{-# LANGUAGE CPP #-}

module Tests.Connection (runTests) where

import Test.QuickCheck
import Test.QuickCheck.Test
import Test.QuickCheck.Monadic as QM

import Tests.Common
import Tests.Certificate

import Text.Printf
import Data.Word
import Test.QuickCheck
import Test.QuickCheck.Test
import Test.QuickCheck.Monadic as QM

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L

import Data.Either
import Data.PEM
import Data.Certificate.X509
import qualified Data.Certificate.KeyRSA as KeyRSA
import qualified Crypto.Random.AESCtr as RNG
import Network.TLS
import Control.Monad
import Control.Monad.Trans (lift)
import Control.Applicative ((<$>))
import Control.Concurrent.Chan
import Control.Concurrent
import Control.Exception (catch, throw, SomeException)
import System.IO

import Network.Socket

import qualified Data.Certificate.KeyRSA as KeyRSA
import qualified Crypto.Cipher.RSA as RSA

import Prelude hiding (catch)

someWords8 :: Int -> Gen [Word8] 
someWords8 i = replicateM i (fromIntegral <$> (choose (0,255) :: Gen Int))

#if MIN_VERSION_QuickCheck(2,3,0)
#else
instance Arbitrary Word8 where
	arbitrary = fromIntegral <$> (choose (0,255) :: Gen Int)
#endif

{- helpers to prepare the tests -}
readCertificate :: FilePath -> IO X509
readCertificate filepath = do
    certs <- rights . parseCerts . pemParseBS <$> B.readFile filepath
    case certs of
        []    -> error "no valid certificate found"
        (x:_) -> return x
    where parseCerts (Right pems) = map (decodeCertificate . L.fromChunks . (:[]) . pemContent)
                                  $ filter (flip elem ["CERTIFICATE", "TRUSTED CERTIFICATE"] . pemName) pems
          parseCerts (Left err) = error "cannot parse PEM file"

readPrivateKey :: FilePath -> IO PrivateKey
readPrivateKey filepath = do
    pk <- rights . parseKey . pemParseBS <$> B.readFile filepath
    case pk of
        []    -> error "no valid RSA key found"
        (x:_) -> return x

    where parseKey (Right pems) = map (fmap (PrivRSA . snd) . KeyRSA.decodePrivate . L.fromChunks . (:[]) . pemContent)
                                $ filter ((== "RSA PRIVATE KEY") . pemName) pems
          parseKey (Left err) = error "Cannot parse PEM file"

arbitraryVersions :: Gen [Version]
arbitraryVersions = resize (length supportedVersions + 1) $ listOf1 (elements supportedVersions)
arbitraryCiphers  = resize (length supportedCiphers + 1) $ listOf1 (elements supportedCiphers)

{- | create a client params and server params that is supposed to
 - result in a valid connection -}
makeValidParams serverCerts = do
	-- it should also generate certificates, key exchange parameters
	-- here instead of taking them from outside.
	-- cert <- arbitraryX509 (PubKey SignatureALG_rsa (PubKeyRSA (0,0,0)))
	allowedVersions <- arbitraryVersions
	connectVersion  <- elements supportedVersions `suchThat` (\c -> c `elem` allowedVersions)

	serverCiphers <- arbitraryCiphers
	clientCiphers <- oneof [arbitraryCiphers] `suchThat`
	                 (\cs -> or [x `elem` serverCiphers | x <- cs])
	secNeg <- arbitrary

	let serverState = defaultParams
		{ pAllowedVersions        = allowedVersions
		, pCiphers                = serverCiphers
		, pCertificates           = serverCerts
		, pUseSecureRenegotiation = secNeg
		}

	let clientState = defaultParams
		{ pConnectVersion         = connectVersion
		, pAllowedVersions        = allowedVersions
		, pCiphers                = clientCiphers
		, pUseSecureRenegotiation = secNeg
		}

	return (clientState, serverState)

{- | setup create all necessary connection point to create a data "pipe"
 -   ---(startQueue)---> tlsClient ---(socketPair)---> tlsServer ---(resultQueue)--->
 -}
setup :: (TLSParams, TLSParams) -> IO (TLSCtx Handle, TLSCtx Handle, Chan a, Chan a)
setup (clientState, serverState) = do
	(cSocket, sSocket) <- socketPair AF_UNIX Stream defaultProtocol
	cHandle            <- socketToHandle cSocket ReadWriteMode
	sHandle            <- socketToHandle sSocket ReadWriteMode

	hSetBuffering cHandle NoBuffering
	hSetBuffering sHandle NoBuffering

	clientRNG   <- RNG.makeSystem
	serverRNG   <- RNG.makeSystem
	startQueue  <- newChan
	resultQueue <- newChan

	cCtx <- client clientState clientRNG cHandle
	sCtx <- server serverState serverRNG sHandle

	return (cCtx, sCtx, startQueue, resultQueue)

testInitiate spCert = do
	states <- pick (makeValidParams spCert)
	(cCtx, sCtx, startQueue, resultQueue) <- run (setup states)

	run $ forkIO $ do
		catch (tlsServer sCtx resultQueue)
		      (\e -> putStrLn ("server exception: " ++ show e) >> throw (e :: SomeException))
		return ()
	run $ forkIO $ do
		catch (tlsClient startQueue cCtx)
		      (\e -> putStrLn ("client exception: " ++ show e) >> throw (e :: SomeException))
		return ()

	{- the test involves writing data on one side of the data "pipe" and
	 - then checking we received them on the other side of the data "pipe" -}
	d <- L.pack <$> pick (someWords8 256)
	run $ writeChan startQueue d

	dres <- run $ readChan resultQueue
	assert $ d == dres

	-- cleanup
	run $ (hClose (ctxConnection cCtx) >> hClose (ctxConnection sCtx))

	where
		tlsServer handle queue = do
			handshake handle
			d <- recvData' handle
			writeChan queue d
			return ()
		tlsClient queue handle = do
			handshake handle
			d <- readChan queue
			sendData handle d
			return ()

runTests = do
	{- FIXME generate the certificate and key with arbitrary, for now rely on special files -}
	cert <- readCertificate "host.cert"
	pk   <- readPrivateKey "host.key"

	run_test "initiate" (monadicIO $ testInitiate [(cert, Just pk)])
