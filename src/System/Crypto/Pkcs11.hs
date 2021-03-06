{-# LANGUAGE CPP #-}

-- | This is the main module that contains bindings for PKCS#11 interface.
module System.Crypto.Pkcs11
  (
    -- * Library
    Library
  , libraryVersion
  , loadLibrary
  , releaseLibrary
    -- ** Reading library information
  , getInfo
  , LibraryInfo
  , infoCryptokiVersion
  , infoManufacturerId
  , infoFlags
  , infoLibraryDescription
  , infoLibraryVersion
  , Version
  , versionMajor
  , versionMinor
    -- * Slots
  , SlotId
  , getSlotNum
  , getSlotList
    -- ** Reading slot information
  , getSlotInfo
  , SlotInfo
  , slotInfoDescription
  , slotInfoManufacturerId
  , slotInfoFlags
  , slotInfoHardwareVersion
  , slotInfoFirmwareVersion
    -- ** Working with tokens
  , TokenInfo
  , getTokenInfo
  , tokenInfoLabel
  , tokenInfoManufacturerId
  , tokenInfoModel
  , tokenInfoSerialNumber
  , tokenInfoFlags
  , initToken
  , initPin
  , setPin
    -- * Mechanisms
  , getMechanismList
  , getMechanismInfo
  , MechType(..)
  , MechInfo
  , mechInfoMinKeySize
  , mechInfoMaxKeySize
  , mechInfoFlags
  , Mech
  , simpleMech
    -- * Session management
  , Session
  , withSession
  , withROSession
  , withRWSession
  , login
  , UserType(..)
  , logout
  , getSessionInfo
  , SessionInfo
  , sessionInfoSlotId
  , sessionInfoState
  , sessionInfoFlags
  , sessionInfoDeviceError
  , SessionState(..)
  , getOperationState
    -- * Object attributes
  , Object
  , destroyObject
  , createObject
  , copyObject
  , getObjectSize
    -- ** Searching objects
  , findObjects
    -- * Key generation
  , generateKey
  , generateKeyPair
  , deriveKey
    -- * Key wrapping/unwrapping
  , wrapKey
  , unwrapKey
    -- * Encryption/decryption
  , decrypt
  , encrypt
    -- * Digest
  , digest
    -- * Signing
  , sign
  , verify
  , signRecover
    -- * Random
  , seedRandom
  , generateRandom
  ) where

import Bindings.Pkcs11
import Bindings.Pkcs11.Attribs
import Bindings.Pkcs11.Shared
import Control.Exception
import Control.Monad
import Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BU8
import Data.ByteString.Unsafe
import Data.List
import Data.Word
import Foreign.C.Types
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.Marshal.Utils
import Foreign.Ptr
import Foreign.Storable
#if defined(mingw32_HOST_OS)
import qualified System.Win32.DLL as DLL
import qualified System.Win32.Types

type DL = System.Win32.Types.HINSTANCE

data RTDLFlags = RTLD_LAZY

dlclose = DLL.freeLibrary

dlopen path _ = DLL.loadLibrary path

dlsym lib fname = do
  addr <- DLL.getProcAddress lib fname
  return $ castPtrToFunPtr addr
#else
import System.Posix.DynamicLinker
#endif
-- | Represents a PKCS#11 library.
data Library = Library
  { libraryHandle :: DL
  , functionListPtr :: FunctionListPtr
  , libraryVersion :: Version  -- ^ Library's Cryptoki version
  }

-- | Return parameterless mechanism which can be used in cryptographic operation.
simpleMech :: MechType -> Mech
simpleMech mechType = Mech mechType nullPtr 0


foreign import ccall unsafe "dynamic"
  mkGetFunctionListFun :: GetFunctionListFunPtr -> GetFunctionListFun

callGetFunctionList :: GetFunctionListFunPtr -> IO FunctionListPtr
callGetFunctionList getFunctionListPtr =
  alloca $ \funcListPtrPtr -> do
    rv <- mkGetFunctionListFun getFunctionListPtr funcListPtrPtr
    if rv /= 0
      then fail $ "failed to get list of functions " ++ rvToStr rv
      else peek funcListPtrPtr

initialize functionListPtr initArgs =
  with initArgs $ \initArgsPtr -> do
    rv <- initialize' functionListPtr (castPtr initArgsPtr)
    when (rv /= 0) $ fail $ "failed to initialize library " ++ rvToStr rv

-- | Load PKCS#11 dynamically linked library from given path and initialize it
--
-- > lib <- loadLibrary "/path/to/dll.so"
loadLibrary :: String -> IO Library
loadLibrary libraryPath = do
  lib <- dlopen libraryPath [RTLD_LAZY]
  getFunctionListFunPtr <- dlsym lib "C_GetFunctionList"
  functionListPtr <- callGetFunctionList getFunctionListFunPtr
  cryptokiVer <- getFunctionListVersion functionListPtr
  initialize functionListPtr InitializeArgs {initArgsFlags=0}
  return Library {libraryHandle = lib, functionListPtr = functionListPtr, libraryVersion = cryptokiVer}

-- | Releases resources used by loaded library
releaseLibrary (Library handle functionListPtr _) = do
  rv <- finalize functionListPtr nullPtr
  when (rv /= 0) $ fail $ "failed to finalize library " ++ rvToStr rv
  dlclose handle

-- | Return number of slots in the system.
getSlotNum ::
     Library -- ^ Library to be used for operation.
  -> Bool -- ^ If True will return only slots with tokens in them.
  -> IO CULong -- ^ Number of slots.
getSlotNum (Library _ functionListPtr _) active = do
  (rv, outNum) <- getSlotList' functionListPtr active nullPtr 0
  if rv /= 0
    then fail $ "failed to get number of slots " ++ rvToStr rv
    else return outNum

-- | Get a list of slot IDs in the system.  Can filter for slots with attached tokens.
--
-- > slotsIds <- getSlotList lib True 10
--
-- In this example retrieves list of, at most 10 (third parameter) slot identifiers with tokens present (second parameter is set to True)
getSlotList ::
     Library -- ^ Library to be used for operation.
  -> Bool -- ^ If True will return only slots with tokens in them.
  -> Int -- ^ Maximum number of slot IDs to be returned.
  -> IO [SlotId]
getSlotList (Library _ functionListPtr _) active num =
  allocaArray num $ \array -> do
    (rv, outNum) <- getSlotList' functionListPtr active array (fromIntegral num)
    if rv /= 0
      then fail $ "failed to get list of slots " ++ rvToStr rv
      else peekArray (fromIntegral outNum) array

getSessionInfo (Session sessHandle funListPtr) = do
  (rv, sessInfo) <- getSessionInfo' funListPtr sessHandle
  if rv /= 0
    then fail $ "failed to get session info: " ++ rvToStr rv
    else return sessInfo

closeAllSessions (Library _ funcListPtr _) slotId = do
  rv <- closeAllSessions' funcListPtr slotId
  when (rv /= 0) $ fail $ "failed to close sessions: " ++ rvToStr rv

getOperationState (Session sessHandle funcListPtr) maxSize =
  allocaBytes (fromIntegral maxSize) $ \bytesPtr -> do
    (rv, resSize) <- getOperationState' funcListPtr sessHandle bytesPtr maxSize
    if rv /= 0
      then fail $ "failed to get operation state: " ++ rvToStr rv
      else BS.packCStringLen (castPtr bytesPtr, fromIntegral resSize)

-- | Deletes an object from token or session.
destroyObject (Object funcListPtr sessHandle objectHandle) = do
  rv <- destroyObject' funcListPtr sessHandle objectHandle
  when (rv /= 0) $ fail $ "failed to destroy object: " ++ rvToStr rv

-- | Generates a symmetric key using provided mechanism and applies provided attributes to resulting key object.
--
-- Examples:
--
-- Generate 128-bit AES key:
--
-- > keyHandle <- generateKey sess (simpleMech AesKeyGen) [ValueLen 16]
--
-- Generate 1024-bit Diffie-Hellman domain parameters using PKCS#3 mechanism:
--
-- > dhParamsHandle <- generateKey sess (simpleMech DhPkcsParameterGen) [PrimeBits 1028]
generateKey :: Mech -> [Attribute] -> Session -> IO Object
generateKey mech attribs (Session sessHandle funcListPtr) =
  _withAttribs attribs $ \attrPtr -> do
    (rv, keyHandle) <- generateKey' funcListPtr sessHandle mech attrPtr (fromIntegral $ length attribs)
    if rv /= 0
      then fail $ "failed to generate key: " ++ rvToStr rv
      else return $ Object funcListPtr sessHandle keyHandle

-- | Get general information about Cryptoki library
getInfo :: Library -> IO LibraryInfo
getInfo (Library _ functionListPtr _) = do
  (rv, info) <- getInfo' functionListPtr
  if rv /= 0
    then fail $ "failed to get library information " ++ rvToStr rv
    else return info

_openSessionEx :: Library -> SlotId -> Int -> IO Session
_openSessionEx (Library _ functionListPtr _) slotId flags = do
  (rv, sessionHandle) <- openSession' functionListPtr slotId flags
  if rv /= 0
    then fail $ "failed to open slot: " ++ rvToStr rv
    else return $ Session sessionHandle functionListPtr

_closeSessionEx :: Session -> IO ()
_closeSessionEx (Session sessionHandle functionListPtr) = do
  rv <- closeSession' functionListPtr sessionHandle
  when (rv /= 0) $ fail $ "failed to close slot: " ++ rvToStr rv

-- | Opens a read-only or read-write session with a token in a given slot and then closes it after callback function is finished.
withSession ::
     Bool -- ^ If True will open writable session, otherwise will open read-only session.
  -> Library -- ^ Library to use.
  -> SlotId -- ^ Slot ID for which to open session.
  -> (Session -> IO a) -- ^ Callback function which is executed while session is open.
  -> IO a -- ^ Returns a result of callback function.
withSession writable lib slotId f = do
  let flags =
        if writable
          then _rwSession
          else 0
  bracket (_openSessionEx lib slotId (flags .|. _serialSession)) _closeSessionEx f

withRWSession = withSession True

withROSession = withSession False

_findObjectsInit :: Session -> [Attribute] -> IO ()
_findObjectsInit (Session sessionHandle functionListPtr) attribs =
  _withAttribs attribs $ \attribsPtr -> do
    rv <- findObjectsInit' functionListPtr sessionHandle attribsPtr (fromIntegral $ length attribs)
    when (rv /= 0) $ fail $ "failed to initialize search: " ++ rvToStr rv

_findObjectsEx :: Session -> IO [Object]
_findObjectsEx (Session sessionHandle functionListPtr) = do
  (rv, objectsHandles) <- findObjects' functionListPtr sessionHandle 10
  if rv /= 0
    then fail $ "failed to execute search: " ++ rvToStr rv
    else return $ map (Object functionListPtr sessionHandle) objectsHandles

_findObjectsFinalEx :: Session -> IO ()
_findObjectsFinalEx (Session sessionHandle functionListPtr) = do
  rv <- findObjectsFinal' functionListPtr sessionHandle
  when (rv /= 0) $ fail $ "failed to finalize search: " ++ rvToStr rv

-- | Searches current session for objects matching provided attributes list, returns a list of matching object handles
findObjects :: Session -> [Attribute] -> IO [Object]
findObjects session attribs = do
  _findObjectsInit session attribs
  finally (_findObjectsEx session) (_findObjectsFinalEx session)

-- | Generates an asymmetric key pair using provided mechanism.
--
-- Examples:
--
-- Generate an 2048-bit RSA key:
--
-- > (pubKey, privKey) <- generateKeyPair sess (simpleMech RsaPkcsKeyPairGen) [ModulusBits 2048] []
generateKeyPair ::
     Mech -- ^ a mechanism to use for key generation, for example 'simpleMech RsaPkcs'
  -> [Attribute] -- ^ attributes applied to generated public key object
  -> [Attribute] -- ^ attributes applied to generated private key object
  -> Session -- ^ session in which to generate key
  -> IO (Object, Object) -- ^ created objects references, first is public key, second is private key
generateKeyPair mech pubKeyAttrs privKeyAttrs (Session sessionHandle functionListPtr) =
  _withAttribs pubKeyAttrs $ \pubAttrsPtr ->
    _withAttribs privKeyAttrs $ \privAttrsPtr -> do
      (rv, pubKeyHandle, privKeyHandle) <-
        generateKeyPair'
          functionListPtr
          sessionHandle
          mech
          pubAttrsPtr
          (fromIntegral $ length pubKeyAttrs)
          privAttrsPtr
          (fromIntegral $ length privKeyAttrs)
      if rv /= 0
        then fail $ "failed to generate key pair: " ++ rvToStr rv
        else return
               (Object functionListPtr sessionHandle pubKeyHandle, Object functionListPtr sessionHandle privKeyHandle)

-- | Initialize a token in a given slot.  All objects created by user on the token are destroyed.
initToken ::
     Library -- ^ PKCS#11 library
  -> SlotId -- ^ slot id in which to initialize token
  -> BU8.ByteString -- ^ token's security officer password
  -> String -- ^ new label for the token
  -> IO ()
initToken (Library _ funcListPtr _) slotId pin label = do
  rv <- initToken' funcListPtr slotId pin label
  when (rv /= 0) $ fail $ "failed to initialize token " ++ rvToStr rv

-- | Obtains information about a particular slot in the system
--
-- > slotInfo <- getSlotInfo lib slotId
getSlotInfo :: Library -> SlotId -> IO SlotInfo
getSlotInfo (Library _ functionListPtr _) slotId = do
  (rv, slotInfo) <- getSlotInfo' functionListPtr slotId
  if rv /= 0
    then fail $ "failed to get slot information " ++ rvToStr rv
    else return slotInfo

-- | Obtains information about a particular token in the system
--
-- > tokenInfo <- getTokenInfo lib slotId
getTokenInfo :: Library -> SlotId -> IO TokenInfo
getTokenInfo (Library _ functionListPtr _) slotId = do
  (rv, slotInfo) <- getTokenInfo' functionListPtr slotId
  if rv /= 0
    then fail $ "failed to get token information " ++ rvToStr rv
    else return slotInfo

-- | Derives a key from a base key using provided mechanism and applies provided attributes to a resulting key.
-- Can be used to derive symmetric key using Diffie-Hellman key exchange.
deriveKey (Session sessHandle funcListPtr) mech baseKeyHandle attribs =
  _withAttribs attribs $ \attribsPtr -> do
    (rv, createdHandle) <-
      deriveKey' funcListPtr sessHandle mech baseKeyHandle attribsPtr (fromIntegral $ length attribs)
    if rv /= 0
      then fail $ "failed to derive key: " ++ rvToStr rv
      else return createdHandle

-- | Creates an object from given list of attributes and returns a reference to created object.
createObject (Session sessHandle funcListPtr) attribs =
  _withAttribs attribs $ \attribsPtr -> do
    (rv, createdHandle) <- createObject' funcListPtr sessHandle attribsPtr (fromIntegral $ length attribs)
    if rv /= 0
      then fail $ "failed to create object: " ++ rvToStr rv
      else return createdHandle

-- | Makes a copy of an object and changes attributes of copied object, returns a reference to new object.
copyObject (Object funcListPtr sessHandle objHandle) attribs =
  _withAttribs attribs $ \attribsPtr -> do
    (rv, createdHandle) <- copyObject' funcListPtr sessHandle objHandle attribsPtr (fromIntegral $ length attribs)
    if rv /= 0
      then fail $ "failed to copy object: " ++ rvToStr rv
      else return createdHandle

-- | Returns an approximate amount of space occupied by an object in bytes.
getObjectSize (Object funcListPtr sessHandle objHandle) = do
  (rv, objSize) <- getObjectSize' funcListPtr sessHandle objHandle
  if rv /= 0
    then fail $ "failed to get object size: " ++ rvToStr rv
    else return objSize

-- | Initializes normal user's PIN.  Session should be logged in by SO user in other words it should be in
-- 'RWSOFunctions' state.
initPin :: Session -> BU8.ByteString -> IO ()
initPin (Session sessHandle funcListPtr) pin = do
  rv <- initPin' funcListPtr sessHandle pin
  when (rv /= 0) $ fail $ "initPin failed: " ++ rvToStr rv

-- | Changes PIN of a currently logged in user.
setPin ::
     Session -- ^ session to act on
  -> BU8.ByteString -- ^ old PIN
  -> BU8.ByteString -- ^ new PIN
  -> IO ()
setPin (Session sessHandle funcListPtr) oldPin newPin = do
  rv <- setPin' funcListPtr sessHandle oldPin newPin
  when (rv /= 0) $ fail $ "setPin failed: " ++ rvToStr rv

-- | Logs a user into a token.
login ::
     Session -- ^ session to act on
  -> UserType -- ^ type of user to login
  -> BU8.ByteString -- ^ user's PIN
  -> IO ()
login (Session sessionHandle functionListPtr) userType pin = do
  rv <- _login functionListPtr sessionHandle userType pin
  when (rv /= 0) $ fail $ "login failed: " ++ rvToStr rv

-- | Logs a user out from a token.
logout :: Session -> IO ()
logout (Session sessionHandle functionListPtr) = do
  rv <- logout' functionListPtr sessionHandle
  when (rv /= 0) $ fail $ "logout failed: " ++ rvToStr rv

-- | Decrypt data using provided mechanism and key handle.
--
-- Example AES ECB decryption.
--
-- > decData <- decrypt (simpleMech AesEcb) sess aesKeyHandle encData Nothing
decrypt ::
     Mech -- ^ Mechanism used for decryption.
  -> Object -- ^ Key object used for decryption.
  -> BS.ByteString -- ^ Encrypted data to be decrypted.
  -> Maybe CULong -- ^ Maximum number of bytes to be returned.
  -> IO BS.ByteString -- ^ Decrypted data
decrypt mech (Object functionListPtr sessionHandle keyHandle) encData maybeOutLen = do
  decryptInit mech (Object functionListPtr sessionHandle keyHandle)
  unsafeUseAsCStringLen encData $ \(encDataPtr, encDataLen) -> do
    (rv, bs) <-
      varLenGet maybeOutLen $ \(ptr, len) ->
        decrypt' functionListPtr sessionHandle (castPtr encDataPtr) (fromIntegral encDataLen) (castPtr ptr) len
    if rv /= 0
      then fail $ "failed to decrypt: " ++ rvToStr rv
      else return bs

-- | Encrypt data using provided mechanism and key handle.
encrypt ::
     Mech -- ^ Mechanism to use for encryption.
  -> Object -- ^ Encryption key.
  -> BS.ByteString -- ^ Data to be encrypted.
  -> Maybe CULong -- ^ Maximum number of bytes to be returned.
  -> IO BS.ByteString -- ^ Encrypted data.
encrypt mech (Object functionListPtr sessionHandle keyHandle) encData maybeOutLen = do
  encryptInit mech (Object functionListPtr sessionHandle keyHandle)
  unsafeUseAsCStringLen encData $ \(encDataPtr, encDataLen) -> do
    (rv, bs) <-
      varLenGet maybeOutLen $
      uncurry (encrypt' functionListPtr sessionHandle (castPtr encDataPtr) (fromIntegral encDataLen))
    if rv /= 0
      then fail $ "failed to decrypt: " ++ rvToStr rv
      else return bs

-- | Calculates digest aka hash of a data using provided mechanism.
--
-- Example calculating SHA256 hash:
--
-- >>> digest (simpleMech Sha256) sess (replicate 16 0) Nothing
-- "7G\b\255\247q\157\213\151\158\200u\213l\210(om<\247\236\&1z;%c*\171(\236\&7\187"
digest ::
     Mech -- ^ Digest mechanism.
  -> Session -- ^ Session to be used for digesting.
  -> BS.ByteString -- ^ Data to be digested.
  -> Maybe CULong -- ^ Maximum number of bytes to be returned.
  -> IO BS.ByteString -- ^ Resulting digest.
digest mech (Session sessHandle funcListPtr) digestData maybeOutLen = do
  digestInit mech (Session sessHandle funcListPtr)
  unsafeUseAsCStringLen digestData $ \(digestDataPtr, digestDataLen) -> do
    (rv, bs) <-
      varLenGet maybeOutLen $
      uncurry (digest' funcListPtr sessHandle (castPtr digestDataPtr) (fromIntegral digestDataLen))
    if rv /= 0
      then fail $ "failed to digest: " ++ rvToStr rv
      else return bs

-- | Signs data using provided mechanism and key.
--
-- Example signing with RSA PKCS#1
--
-- > signature <- sign (simpleMech RsaPkcs) sess privKeyHandle signedData Nothing
sign ::
     Mech -- ^ Mechanism to use for signing.
  -> Object -- ^ Signing key (usually private key).
  -> BS.ByteString -- ^ Data to be signed.
  -> Maybe CULong -- ^ Maximum number of bytes to be returned.
  -> IO BS.ByteString -- ^ Signature.
sign mech (Object funcListPtr sessHandle key) signData maybeOutLen = do
  signInit mech (Object funcListPtr sessHandle key)
  unsafeUseAsCStringLen signData $ \(signDataPtr, signDataLen) -> do
    (rv, bs) <-
      varLenGet maybeOutLen $ uncurry (sign' funcListPtr sessHandle (castPtr signDataPtr) (fromIntegral signDataLen))
    if rv /= 0
      then fail $ "failed to sign: " ++ rvToStr rv
      else return bs

-- | Signs data with mechanism which allows data recovery from signature
signRecover ::
     Mech -- ^ Mechanism to use for signing.
  -> Object -- ^ Signing key (usually private key).
  -> BS.ByteString -- ^ Data to be signed.
  -> Maybe CULong -- ^ Maximum number of bytes to be returned.
  -> IO BS.ByteString -- ^ Signature.
signRecover mech (Object funcListPtr sessHandle key) signData maybeOutLen = do
  signRecoverInit mech (Object funcListPtr sessHandle key)
  unsafeUseAsCStringLen signData $ \(signDataPtr, signDataLen) -> do
    (rv, bs) <-
      varLenGet maybeOutLen $
      uncurry (signRecover' funcListPtr sessHandle (castPtr signDataPtr) (fromIntegral signDataLen))
    if rv /= 0
      then fail $ "failed to sign with recovery: " ++ rvToStr rv
      else return bs

-- | Verifies signature using provided mechanism and key.
--
-- Example signature verification using RSA public key:
--
-- >>> verify (simpleMech RsaPkcs) sess pubKeyHandle signedData signature
-- True
verify ::
     Mech -- ^ Mechanism to be used for signature validation.
  -> Object -- ^ Verification key (usually public key).
  -> BS.ByteString -- ^ Signed data.
  -> BS.ByteString -- ^ Signature.
  -> IO Bool -- ^ True is signature is valid, False otherwise.
verify mech (Object funcListPtr sessHandle keyHandle) signData signatureData = do
  verifyInit mech (Object funcListPtr sessHandle keyHandle)
  unsafeUseAsCStringLen signData $ \(signDataPtr, signDataLen) ->
    unsafeUseAsCStringLen signatureData $ \(signatureDataPtr, signatureDataLen) -> do
      rv <-
        verify'
          funcListPtr
          sessHandle
          (castPtr signDataPtr)
          (fromIntegral signDataLen)
          (castPtr signatureDataPtr)
          (fromIntegral signatureDataLen)
      if rv == 0
        then return True
        else if rv == errSignatureInvalid
               then return False
               else fail $ "failed to verify: " ++ rvToStr rv

-- | Wrap a key using provided wrapping key and return opaque byte array representing wrapped key.  This byte array
-- can be stored in user application and can be used later to recreate wrapped key using 'unwrapKey' function.
--
-- Example wrapping AES key using RSA public key:
--
-- > wrappedAesKey <- wrapKey (simpleMech RsaPkcs) sess pubRsaKeyHandle aesKeyHandle Nothing
wrapKey ::
     Mech -- ^ Mechanism used to wrap key (to encrypt)
  -> Object -- ^ Key which will be used to wrap (encrypt) another key
  -> Object -- ^ Key to be wrapped
  -> Maybe CULong -- ^ Maximum size in bytes of a resulting byte array
  -> IO BS.ByteString -- ^ Resulting opaque wrapped key
wrapKey mech (Object funcListPtr sessHandle wrappingKey) (Object _ _ key) maybeOutLen = do
  (rv, bs) <- varLenGet maybeOutLen $ uncurry (wrapKey' funcListPtr sessHandle mech wrappingKey key)
  if rv /= 0
    then fail $ "failed to wrap key: " ++ rvToStr rv
    else return bs

-- | Unwrap a key from opaque byte string and apply attributes to a resulting key object.
--
-- Example unwrapping AES key using RSA private key:
--
-- > unwrappedAesKey <- unwrapKey (simpleMech RsaPkcs) sess privRsaKeyHandle wrappedAesKey [Class SecretKey, KeyType AES]
unwrapKey ::
     Mech -- ^ Mechanism to use for unwrapping (decryption).
  -> Object -- ^ Handle to a key which will be used to unwrap (decrypt) key.
  -> BS.ByteString -- ^ Key to be unwrapped.
  -> [Attribute] -- ^ Attributes applied to unwrapped key object.
  -> IO Object -- ^ Unwrapped key handle.
unwrapKey mech (Object functionListPtr sessionHandle key) wrappedKey template =
  _withAttribs template $ \attribsPtr ->
    unsafeUseAsCStringLen wrappedKey $ \(wrappedKeyPtr, wrappedKeyLen) -> do
      (rv, unwrappedKey) <-
        unwrapKey'
          functionListPtr
          sessionHandle
          mech
          key
          (castPtr wrappedKeyPtr)
          (fromIntegral wrappedKeyLen)
          attribsPtr
          (fromIntegral $ length template)
      if rv /= 0
        then fail $ "failed to unwrap key: " ++ rvToStr rv
        else return $ Object functionListPtr sessionHandle unwrappedKey

-- | Mixes provided seed data with token's seed
seedRandom ::
     Session -- ^ Session to use
  -> BS.ByteString -- ^ Seed data to be added to RNG's seed
  -> IO ()
seedRandom (Session sessHandle funcListPtr) seedData =
  unsafeUseAsCStringLen seedData $ \(seedDataPtr, seedDataLen) -> do
    rv <- seedRandom' funcListPtr sessHandle (castPtr seedDataPtr) (fromIntegral seedDataLen)
    when (rv /= 0) $ fail $ "failed to seed random: " ++ rvToStr rv

-- | Generates random data using token's RNG.
generateRandom ::
     Session -- ^ Session to work on.
  -> CULong -- ^ Number of bytes to generate.
  -> IO BS.ByteString -- ^ Generated random bytes.
generateRandom (Session sessHandle funcListPtr) randLen =
  allocaBytes (fromIntegral randLen) $ \randPtr -> do
    rv <- generateRandom' funcListPtr sessHandle randPtr randLen
    if rv /= 0
      then fail $ "failed to generate random data: " ++ rvToStr rv
      else BS.packCStringLen (castPtr randPtr, fromIntegral randLen)

-- | Obtains a list of mechanism types supported by a token
getMechanismList :: Library -> SlotId -> Int -> IO [Int]
getMechanismList (Library _ functionListPtr _) slotId maxMechanisms =
  allocaArray maxMechanisms $ \array -> do
    (rv, outArrayLen) <- getMechanismList' functionListPtr slotId array (fromIntegral maxMechanisms)
    if rv /= 0
      then fail $ "failed to get list of mechanisms: " ++ rvToStr rv
      else do
        mechsIds <- peekArray (fromIntegral outArrayLen) array
        return $ map fromIntegral mechsIds

-- | Obtains information about a particular mechanism possibly supported by a token
getMechanismInfo :: Library -> SlotId -> MechType -> IO MechInfo
getMechanismInfo (Library _ functionListPtr _) slotId mechId = do
  (rv, types) <- _getMechanismInfo functionListPtr slotId (fromEnum mechId)
  if rv /= 0
    then fail $ "failed to get mechanism information: " ++ rvToStr rv
    else return types