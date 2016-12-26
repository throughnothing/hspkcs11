{-# LANGUAGE ForeignFunctionInterface #-}
module Pkcs11 where
import Foreign
import Foreign.Marshal.Utils
import Foreign.Marshal.Alloc
import Foreign.C
import Foreign.Ptr
import System.Posix.DynamicLinker
import Control.Monad
import Control.Exception
import qualified Data.ByteString.UTF8 as BU8
import Data.ByteString.Unsafe

#include "pkcs11import.h"

{-
 Currently cannot use c2hs structure alignment and offset detector since it does not support pragma pack
 which is required by PKCS11, which is using 1 byte packing
 https://github.com/haskell/c2hs/issues/172
-}

serialSession = {#const CKF_SERIAL_SESSION#} :: Int
rsaPkcsKeyPairGen = {#const CKM_RSA_PKCS_KEY_PAIR_GEN#} :: Int

type ObjectHandle = {#type CK_OBJECT_HANDLE#}
type SlotId = {#type CK_SLOT_ID#}
type Rv = {#type CK_RV#}
type CK_BYTE = {#type CK_BYTE#}
type CK_FLAGS = {#type CK_FLAGS#}
type GetFunctionListFunPtr = {#type CK_C_GetFunctionList#}
type GetSlotListFunPtr = {#type CK_C_GetSlotList#}
type NotifyFunPtr = {#type CK_NOTIFY#}
type SessionHandle = {#type CK_SESSION_HANDLE#}

{#pointer *CK_FUNCTION_LIST as FunctionListPtr#}
{#pointer *CK_INFO as InfoPtr -> Info#}
{#pointer *CK_SLOT_INFO as SlotInfoPtr -> SlotInfo#}
{#pointer *CK_TOKEN_INFO as TokenInfoPtr -> TokenInfo#}
{#pointer *CK_ATTRIBUTE as LlAttributePtr -> LlAttribute#}
{#pointer *CK_MECHANISM_INFO as MechInfoPtr -> MechInfo#}
{#pointer *CK_MECHANISM as MechPtr -> Mech#}

-- defined this one manually because I don't know how to make c2hs to define it yet
type GetFunctionListFun = (C2HSImp.Ptr (FunctionListPtr)) -> (IO C2HSImp.CULong)

foreign import ccall unsafe "dynamic"
  getFunctionList'_ :: GetFunctionListFunPtr -> GetFunctionListFun

data Version = Version {
    versionMajor :: Int,
    versionMinor :: Int
} deriving (Show)

instance Storable Version where
  sizeOf _ = {#sizeof CK_VERSION#}
  alignment _ = {#alignof CK_VERSION#}
  peek p = Version
    <$> liftM fromIntegral ({#get CK_VERSION->major#} p)
    <*> liftM fromIntegral ({#get CK_VERSION->minor#} p)
  poke p x = do
    {#set CK_VERSION->major#} p (fromIntegral $ versionMajor x)
    {#set CK_VERSION->minor#} p (fromIntegral $ versionMinor x)

data Info = Info {
    infoCryptokiVersion :: Version,
    infoManufacturerId :: String,
    infoFlags :: CK_FLAGS,
    infoLibraryDescription :: String,
    infoLibraryVersion :: Version
} deriving (Show)

instance Storable Info where
  sizeOf _ = (2+32+4+32+10+2){-#sizeof CK_INFO#-}
  alignment _ = 1{-#alignof CK_INFO#-}
  peek p = do
    ver <- peek (p `plusPtr` {#offsetof CK_INFO->cryptokiVersion#}) :: IO Version
    manufacturerId <- peekCStringLen ((p `plusPtr` 2{-#offsetof CK_INFO->manufacturerID#-}), 32)
    flags <- (\ptr -> do {C2HSImp.peekByteOff ptr (2+32) :: IO C2HSImp.CULong}) p
    --flags <- {#get CK_INFO->flags#} p
    libraryDescription <- peekCStringLen ((p `plusPtr` (2+32+4+10){-#offsetof CK_INFO->libraryDescription#-}), 32)
    --libraryDescription <- {# get CK_INFO->libraryDescription #} p
    libVer <- peek (p `plusPtr` (2+32+4+32+10){-#offsetof CK_INFO->libraryVersion#-}) :: IO Version
    return Info {infoCryptokiVersion=ver,
                 infoManufacturerId=manufacturerId,
                 infoFlags=fromIntegral flags,
                 infoLibraryDescription=libraryDescription,
                 infoLibraryVersion=libVer
                 }


peekInfo :: Ptr Info -> IO Info
peekInfo ptr = peek ptr


data SlotInfo = SlotInfo {
    slotInfoDescription :: String,
    slotInfoManufacturerId :: String,
    slotInfoFlags :: Int,
    slotInfoHardwareVersion :: Version,
    slotInfoFirmwareVersion :: Version
} deriving (Show)

instance Storable SlotInfo where
  sizeOf _ = (64+32+4+2+2){-#sizeof CK_INFO#-}
  alignment _ = 1{-#alignof CK_INFO#-}
  peek p = do
    description <- peekCStringLen ((p `plusPtr` 0{-#offsetof CK_SLOT_INFO->slotDescription#-}), 64)
    manufacturerId <- peekCStringLen ((p `plusPtr` 64{-#offsetof CK_SLOT_INFO->manufacturerID#-}), 32)
    flags <- C2HSImp.peekByteOff p (64+32) :: IO C2HSImp.CULong
    hwVer <- peek (p `plusPtr` (64+32+4){-#offsetof CK_SLOT_INFO->hardwareVersion#-}) :: IO Version
    fwVer <- peek (p `plusPtr` (64+32+4+2){-#offsetof CK_SLOT_INFO->firmwareVersion#-}) :: IO Version
    return SlotInfo {slotInfoDescription=description,
                     slotInfoManufacturerId=manufacturerId,
                     slotInfoFlags=fromIntegral flags,
                     slotInfoHardwareVersion=hwVer,
                     slotInfoFirmwareVersion=fwVer
                     }


data TokenInfo = TokenInfo {
    tokenInfoLabel :: String,
    tokenInfoManufacturerId :: String,
    tokenInfoModel :: String,
    tokenInfoSerialNumber :: String,
    tokenInfoFlags :: Int--,
    --tokenInfoHardwareVersion :: Version,
    --tokenInfoFirmwareVersion :: Version
} deriving (Show)

instance Storable TokenInfo where
    sizeOf _ = (64+32+4+2+2){-#sizeof CK_INFO#-}
    alignment _ = 1{-#alignof CK_INFO#-}
    peek p = do
        label <- peekCStringLen ((p `plusPtr` 0{-#offsetof CK_SLOT_INFO->slotDescription#-}), 32)
        manufacturerId <- peekCStringLen ((p `plusPtr` 32{-#offsetof CK_SLOT_INFO->manufacturerID#-}), 32)
        model <- peekCStringLen ((p `plusPtr` (32+32){-#offsetof CK_SLOT_INFO->manufacturerID#-}), 16)
        serialNumber <- peekCStringLen ((p `plusPtr` (32+32+16){-#offsetof CK_SLOT_INFO->manufacturerID#-}), 16)
        flags <- C2HSImp.peekByteOff p (32+32+16+16) :: IO C2HSImp.CULong
        --hwVer <- peek (p `plusPtr` (64+32+4){-#offsetof CK_SLOT_INFO->hardwareVersion#-}) :: IO Version
        --fwVer <- peek (p `plusPtr` (64+32+4+2){-#offsetof CK_SLOT_INFO->firmwareVersion#-}) :: IO Version
        return TokenInfo {tokenInfoLabel=label,
                          tokenInfoManufacturerId=manufacturerId,
                          tokenInfoModel=model,
                          tokenInfoSerialNumber=serialNumber,
                          tokenInfoFlags=fromIntegral flags--,
                          --tokenInfoHardwareVersion=hwVer,
                          --tokenInfoFirmwareVersion=fwVer
                          }


data MechInfo = MechInfo {
    mechInfoMinKeySize :: Int,
    mechInfoMaxKeySize :: Int,
    mechInfoFlags :: Int
} deriving (Show)

instance Storable MechInfo where
  sizeOf _ = {#sizeof CK_MECHANISM_INFO#}
  alignment _ = 1
  peek p = MechInfo
    <$> liftM fromIntegral ({#get CK_MECHANISM_INFO->ulMinKeySize#} p)
    <*> liftM fromIntegral ({#get CK_MECHANISM_INFO->ulMaxKeySize#} p)
    <*> liftM fromIntegral ({#get CK_MECHANISM_INFO->flags#} p)
  poke p x = do
    {#set CK_MECHANISM_INFO->ulMinKeySize#} p (fromIntegral $ mechInfoMinKeySize x)
    {#set CK_MECHANISM_INFO->ulMaxKeySize#} p (fromIntegral $ mechInfoMaxKeySize x)
    {#set CK_MECHANISM_INFO->flags#} p (fromIntegral $ mechInfoFlags x)


data Mech = Mech {
    mechType :: Int,
    mechParamPtr :: Ptr (),
    mechParamSize :: Int
}

instance Storable Mech where
    sizeOf _ = {#sizeof CK_MECHANISM_TYPE#} + {#sizeof CK_VOID_PTR#} + {#sizeof CK_ULONG#}
    alignment _ = 1
    poke p x = do
        poke (p `plusPtr` 0) (mechType x)
        poke (p `plusPtr` {#sizeof CK_MECHANISM_TYPE#}) (mechParamPtr x :: {#type CK_VOID_PTR#})
        poke (p `plusPtr` ({#sizeof CK_MECHANISM_TYPE#} + {#sizeof CK_VOID_PTR#})) (mechParamSize x)



{#fun unsafe CK_FUNCTION_LIST.C_Initialize as initialize
 {`FunctionListPtr',
  alloca- `()' } -> `Rv' fromIntegral#}

{#fun unsafe CK_FUNCTION_LIST.C_GetInfo as getInfo'
 {`FunctionListPtr',
  alloca- `Info' peekInfo* } -> `Rv' fromIntegral#}


getSlotList' functionListPtr active num = do
  alloca $ \arrayLenPtr -> do
    poke arrayLenPtr (fromIntegral num)
    allocaArray num $ \array -> do
      res <- {#call unsafe CK_FUNCTION_LIST.C_GetSlotList#} functionListPtr (fromBool active) array arrayLenPtr
      arrayLen <- peek arrayLenPtr
      slots <- peekArray (fromIntegral arrayLen) array
      return (fromIntegral res, slots)


{#fun unsafe CK_FUNCTION_LIST.C_GetSlotInfo as getSlotInfo'
  {`FunctionListPtr',
   `Int',
   alloca- `SlotInfo' peek* } -> `Rv' fromIntegral
#}


{#fun unsafe CK_FUNCTION_LIST.C_GetTokenInfo as getTokenInfo'
  {`FunctionListPtr',
   `Int',
   alloca- `TokenInfo' peek* } -> `Rv' fromIntegral
#}


openSession' functionListPtr slotId flags =
  alloca $ \slotIdPtr -> do
    res <- {#call unsafe CK_FUNCTION_LIST.C_OpenSession#} functionListPtr (fromIntegral slotId) (fromIntegral flags) nullPtr nullFunPtr slotIdPtr
    slotId <- peek slotIdPtr
    return (fromIntegral res, fromIntegral slotId)


{#fun unsafe CK_FUNCTION_LIST.C_CloseSession as closeSession'
 {`FunctionListPtr',
  `CULong' } -> `Rv' fromIntegral#}


{#fun unsafe CK_FUNCTION_LIST.C_Finalize as finalize
 {`FunctionListPtr',
  alloca- `()' } -> `Rv' fromIntegral#}


getFunctionList :: GetFunctionListFunPtr -> IO ((Rv), (FunctionListPtr))
getFunctionList getFunctionListPtr =
  alloca $ \funcListPtrPtr -> do
    res <- (getFunctionList'_ getFunctionListPtr) funcListPtrPtr
    funcListPtr <- peek funcListPtrPtr
    return (fromIntegral res, funcListPtr)


findObjectsInit' functionListPtr session attribs = do
    _withAttribs attribs $ \attribsPtr -> do
        res <- {#call unsafe CK_FUNCTION_LIST.C_FindObjectsInit#} functionListPtr session attribsPtr (fromIntegral $ length attribs)
        return (fromIntegral res)


findObjects' functionListPtr session maxObjects = do
  alloca $ \arrayLenPtr -> do
    poke arrayLenPtr (fromIntegral 0)
    allocaArray maxObjects $ \array -> do
      res <- {#call unsafe CK_FUNCTION_LIST.C_FindObjects#} functionListPtr session array (fromIntegral maxObjects) arrayLenPtr
      arrayLen <- peek arrayLenPtr
      objectHandles <- peekArray (fromIntegral arrayLen) array
      return (fromIntegral res, objectHandles)


{#fun unsafe CK_FUNCTION_LIST.C_FindObjectsFinal as findObjectsFinal'
 {`FunctionListPtr',
  `CULong' } -> `Rv' fromIntegral#}


{#enum define UserType {CKU_USER as User, CKU_SO as SecurityOfficer, CKU_CONTEXT_SPECIFIC as ContextSpecific} deriving (Eq,Ord) #}


_login :: FunctionListPtr -> SessionHandle -> UserType -> BU8.ByteString -> IO (Rv)
_login functionListPtr session userType pin = do
    unsafeUseAsCStringLen pin $ \(pinPtr, pinLen) -> do
        res <- {#call unsafe CK_FUNCTION_LIST.C_Login#} functionListPtr session (fromIntegral $ fromEnum userType) (castPtr pinPtr) (fromIntegral pinLen)
        return (fromIntegral res)


_generateKeyPair :: FunctionListPtr -> SessionHandle -> Int -> [Attribute] -> [Attribute] -> IO (Rv, ObjectHandle, ObjectHandle)
_generateKeyPair functionListPtr session mechType pubAttrs privAttrs = do
    alloca $ \pubKeyHandlePtr -> do
        alloca $ \privKeyHandlePtr -> do
            alloca $ \mechPtr -> do
                poke mechPtr (Mech {mechType = mechType, mechParamPtr = nullPtr, mechParamSize = 0})
                _withAttribs pubAttrs $ \pubAttrsPtr -> do
                    _withAttribs privAttrs $ \privAttrsPtr -> do
                        res <- {#call unsafe CK_FUNCTION_LIST.C_GenerateKeyPair#} functionListPtr session mechPtr pubAttrsPtr (fromIntegral $ length pubAttrs) privAttrsPtr (fromIntegral $ length privAttrs) pubKeyHandlePtr privKeyHandlePtr
                        pubKeyHandle <- peek pubKeyHandlePtr
                        privKeyHandle <- peek privKeyHandlePtr
                        return (fromIntegral res, fromIntegral pubKeyHandle, fromIntegral privKeyHandle)



_getMechanismList :: FunctionListPtr -> Int -> Int -> IO (Rv, [CULong])
_getMechanismList functionListPtr slotId maxMechanisms = do
    alloca $ \arrayLenPtr -> do
        poke arrayLenPtr (fromIntegral maxMechanisms)
        allocaArray maxMechanisms $ \array -> do
            res <- {#call unsafe CK_FUNCTION_LIST.C_GetMechanismList#} functionListPtr (fromIntegral slotId) array arrayLenPtr
            arrayLen <- peek arrayLenPtr
            objectHandles <- peekArray (fromIntegral arrayLen) array
            return (fromIntegral res, objectHandles)


{#fun unsafe CK_FUNCTION_LIST.C_GetMechanismInfo as _getMechanismInfo
  {`FunctionListPtr',
   `Int',
   `Int',
   alloca- `MechInfo' peek* } -> `Rv' fromIntegral
#}


rvToStr :: Rv -> String
rvToStr {#const CKR_OK#} = "ok"
rvToStr {#const CKR_ARGUMENTS_BAD#} = "bad arguments"
rvToStr {#const CKR_ATTRIBUTE_READ_ONLY#} = "attribute is read-only"
rvToStr {#const CKR_ATTRIBUTE_TYPE_INVALID#} = "invalid attribute type specified in template"
rvToStr {#const CKR_ATTRIBUTE_TYPE_INVALID#} = "invalid attribute value specified in template"
rvToStr {#const CKR_CRYPTOKI_NOT_INITIALIZED#} = "cryptoki not initialized"
rvToStr {#const CKR_DEVICE_ERROR#} = "device error"
rvToStr {#const CKR_DEVICE_MEMORY#} = "device memory"
rvToStr {#const CKR_DEVICE_REMOVED#} = "device removed"
rvToStr {#const CKR_DOMAIN_PARAMS_INVALID#} = "invalid domain parameters"
rvToStr {#const CKR_FUNCTION_CANCELED#} = "function canceled"
rvToStr {#const CKR_FUNCTION_FAILED#} = "function failed"
rvToStr {#const CKR_GENERAL_ERROR#} = "general error"
rvToStr {#const CKR_HOST_MEMORY#} = "host memory"
rvToStr {#const CKR_MECHANISM_INVALID#} = "invalid mechanism"
rvToStr {#const CKR_MECHANISM_PARAM_INVALID#} = "invalid mechanism parameter"
rvToStr {#const CKR_OPERATION_ACTIVE#} = "there is already an active operation in-progress"
rvToStr {#const CKR_OPERATION_NOT_INITIALIZED#} = "operation was not initialized"
rvToStr {#const CKR_PIN_EXPIRED#} = "PIN is expired, you need to setup a new PIN"
rvToStr {#const CKR_PIN_INCORRECT#} = "PIN is incorrect, authentication failed"
rvToStr {#const CKR_PIN_LOCKED#} = "PIN is locked, authentication failed"
rvToStr {#const CKR_SESSION_CLOSED#} = "session was closed in a middle of operation"
rvToStr {#const CKR_SESSION_COUNT#} = "session count"
rvToStr {#const CKR_SESSION_HANDLE_INVALID#} = "session handle is invalid"
rvToStr {#const CKR_SESSION_PARALLEL_NOT_SUPPORTED#} = "parallel session not supported"
rvToStr {#const CKR_SESSION_READ_ONLY#} = "session is read-only"
rvToStr {#const CKR_SESSION_READ_ONLY_EXISTS#} = "read-only session exists, SO cannot login"
rvToStr {#const CKR_SESSION_READ_WRITE_SO_EXISTS#} = "read-write SO session exists"
rvToStr {#const CKR_SLOT_ID_INVALID#} = "slot id invalid"
rvToStr {#const CKR_TEMPLATE_INCOMPLETE#} = "provided template is incomplete"
rvToStr {#const CKR_TEMPLATE_INCONSISTENT#} = "provided template is inconsistent"
rvToStr {#const CKR_TOKEN_NOT_PRESENT#} = "token not present"
rvToStr {#const CKR_TOKEN_NOT_RECOGNIZED#} = "token not recognized"
rvToStr {#const CKR_TOKEN_WRITE_PROTECTED#} = "token is write protected"
rvToStr {#const CKR_USER_NOT_LOGGED_IN#} = "user needs to be logged in to perform this operation"
rvToStr {#const CKR_USER_ALREADY_LOGGED_IN#} = "user already logged in"
rvToStr {#const CKR_USER_ANOTHER_ALREADY_LOGGED_IN#} = "another user already logged in, first another user should be logged out"
rvToStr {#const CKR_USER_PIN_NOT_INITIALIZED#} = "user PIN not initialized, need to setup PIN first"
rvToStr {#const CKR_USER_TOO_MANY_TYPES#} = "cannot login user, somebody should logout first"
rvToStr {#const CKR_USER_TYPE_INVALID#} = "invalid value for user type"


-- Attributes

data ClassType = Data | Certificate | PublicKey | PrivateKey | SecretKey | HWFeature | DomainParameters | Mechanism
data KeyTypeType = RSA | DSA | DH | ECDSA | EC

data Attribute = Class ClassType | KeyType KeyTypeType | Label String | ModulusBits Int

data LlAttribute = LlAttribute {
    attributeType :: {#type CK_ATTRIBUTE_TYPE#},
    attributeValuePtr :: Ptr (),
    attributeSize :: {#type CK_ULONG#}
}

instance Storable LlAttribute where
  sizeOf _ = {#sizeof CK_ATTRIBUTE_TYPE#} + {#sizeof CK_VOID_PTR#} + {#sizeof CK_ULONG#}
  alignment _ = 1
  poke p x = do
    poke (p `plusPtr` 0) (attributeType x)
    poke (p `plusPtr` {#sizeof CK_ATTRIBUTE_TYPE#}) (attributeValuePtr x :: {#type CK_VOID_PTR#})
    poke (p `plusPtr` ({#sizeof CK_ATTRIBUTE_TYPE#} + {#sizeof CK_VOID_PTR#})) (attributeSize x)


_classTypeVal :: ClassType -> {#type CK_OBJECT_CLASS#}
_classTypeVal Data = {#const CKO_DATA#}
_classTypeVal Certificate = {#const CKO_CERTIFICATE#}
_classTypeVal PublicKey = {#const CKO_PUBLIC_KEY#}
_classTypeVal PrivateKey = {#const CKO_PRIVATE_KEY#}
_classTypeVal SecretKey = {#const CKO_SECRET_KEY#}
_classTypeVal HWFeature = {#const CKO_HW_FEATURE#}
_classTypeVal DomainParameters = {#const CKO_DOMAIN_PARAMETERS#}
_classTypeVal Mechanism = {#const CKO_MECHANISM#}


_keyTypeVal :: KeyTypeType -> {#type CK_KEY_TYPE#}
_keyTypeVal RSA = {#const CKK_RSA#}
_keyTypeVal DSA = {#const CKK_DSA#}
_keyTypeVal DH = {#const CKK_DH#}
_keyTypeVal ECDSA = {#const CKK_ECDSA#}
_keyTypeVal EC = {#const CKK_EC#}


_attrType :: Attribute -> {#type CK_ATTRIBUTE_TYPE#}
_attrType (Class _) = {#const CKA_CLASS#}
_attrType (KeyType _) = {#const CKA_KEY_TYPE#}
_attrType (Label _) = {#const CKA_LABEL#}
_attrType (ModulusBits _) = {#const CKA_MODULUS_BITS#}


_valueSize :: Attribute -> Int
_valueSize (Class _) = {#sizeof CK_OBJECT_CLASS#}
_valueSize (KeyType _) = {#sizeof CK_KEY_TYPE#}
_valueSize (Label l) = BU8.length $ BU8.fromString l
_valueSize (ModulusBits _) = {#sizeof CK_ULONG#}


_pokeValue :: Attribute -> Ptr () -> IO ()
_pokeValue (Class c) ptr = poke (castPtr ptr :: Ptr {#type CK_OBJECT_CLASS#}) (_classTypeVal c :: {#type CK_OBJECT_CLASS#})
_pokeValue (KeyType k) ptr = poke (castPtr ptr :: Ptr {#type CK_KEY_TYPE#}) (_keyTypeVal k :: {#type CK_KEY_TYPE#})
_pokeValue (Label l) ptr = unsafeUseAsCStringLen (BU8.fromString l) $ \(src, len) -> copyBytes ptr (castPtr src :: Ptr ()) len
_pokeValue (ModulusBits l) ptr = poke (castPtr ptr :: Ptr {#type CK_ULONG#}) (fromIntegral l :: {#type CK_KEY_TYPE#})


_pokeValues :: [Attribute] -> Ptr () -> IO ()
_pokeValues [] p = return ()
_pokeValues (a:rem) p = do
    _pokeValue a p
    _pokeValues rem (p `plusPtr` (_valueSize a))


_valuesSize :: [Attribute] -> Int
_valuesSize attribs = foldr (+) 0 (map (_valueSize) attribs)


_makeLowLevelAttrs :: [Attribute] -> Ptr () -> [LlAttribute]
_makeLowLevelAttrs [] valuePtr = []
_makeLowLevelAttrs (a:rem) valuePtr =
    let valuePtr' = valuePtr `plusPtr` (_valueSize a)
        llAttr = LlAttribute {attributeType=_attrType a, attributeValuePtr=valuePtr, attributeSize=(fromIntegral $ _valueSize a)}
    in
        llAttr:(_makeLowLevelAttrs rem valuePtr')


_withAttribs :: [Attribute] -> (Ptr LlAttribute -> IO a) -> IO a
_withAttribs attribs f = do
    allocaBytes (_valuesSize attribs) $ \valuesPtr -> do
        _pokeValues attribs valuesPtr
        allocaArray (length attribs) $ \attrsPtr -> do
            pokeArray attrsPtr (_makeLowLevelAttrs attribs valuesPtr)
            f attrsPtr



-- High level API starts here


data Library = Library {
    libraryHandle :: DL,
    functionListPtr :: FunctionListPtr
}


data Session = Session SessionHandle FunctionListPtr


loadLibrary :: String -> IO Library
loadLibrary libraryPath = do
    lib <- dlopen libraryPath []
    getFunctionListFunPtr <- dlsym lib "C_GetFunctionList"
    (rv, functionListPtr) <- getFunctionList getFunctionListFunPtr
    if rv /= 0
        then fail $ "failed to get list of functions " ++ (rvToStr rv)
        else do
            rv <- initialize functionListPtr
            if rv /= 0
                then fail $ "failed to initialize library " ++ (rvToStr rv)
                else return Library { libraryHandle = lib, functionListPtr = functionListPtr }


releaseLibrary lib = do
    rv <- finalize $ functionListPtr lib
    dlclose $ libraryHandle lib


getInfo :: Library -> IO Info
getInfo (Library _ functionListPtr) = do
    (rv, info) <- getInfo' functionListPtr
    if rv /= 0
        then fail $ "failed to get library information " ++ (rvToStr rv)
        else return info


getSlotList :: Library -> Bool -> Int -> IO [CULong]
getSlotList (Library _ functionListPtr) active num = do
    (rv, slots) <- getSlotList' functionListPtr active num
    if rv /= 0
        then fail $ "failed to get list of slots " ++ (rvToStr rv)
        else return slots


getSlotInfo :: Library -> Int -> IO SlotInfo
getSlotInfo (Library _ functionListPtr) slotId = do
    (rv, slotInfo) <- getSlotInfo' functionListPtr slotId
    if rv /= 0
        then fail $ "failed to get slot information " ++ (rvToStr rv)
        else return slotInfo


getTokenInfo :: Library -> Int -> IO TokenInfo
getTokenInfo (Library _ functionListPtr) slotId = do
    (rv, slotInfo) <- getTokenInfo' functionListPtr slotId
    if rv /= 0
        then fail $ "failed to get token information " ++ (rvToStr rv)
        else return slotInfo


_openSessionEx :: Library -> Int -> Int -> IO Session
_openSessionEx (Library _ functionListPtr) slotId flags = do
    (rv, sessionHandle) <- openSession' functionListPtr slotId flags
    if rv /= 0
        then fail $ "failed to open slot: " ++ (rvToStr rv)
        else return $ Session sessionHandle functionListPtr


_closeSessionEx :: Session -> IO ()
_closeSessionEx (Session sessionHandle functionListPtr) = do
    rv <- closeSession' functionListPtr sessionHandle
    if rv /= 0
        then fail $ "failed to close slot: " ++ (rvToStr rv)
        else return ()


withSession :: Library -> Int -> Int -> (Session -> IO a) -> IO a
withSession lib slotId flags f = do
    bracket
        (_openSessionEx lib slotId flags)
        (_closeSessionEx)
        (f)



_findObjectsInitEx :: Session -> [Attribute] -> IO ()
_findObjectsInitEx (Session sessionHandle functionListPtr) attribs = do
    rv <- findObjectsInit' functionListPtr sessionHandle attribs
    if rv /= 0
        then fail $ "failed to initialize search: " ++ (rvToStr rv)
        else return ()


_findObjectsEx :: Session -> IO [ObjectHandle]
_findObjectsEx (Session sessionHandle functionListPtr) = do
    (rv, objectsHandles) <- findObjects' functionListPtr sessionHandle 10
    if rv /= 0
        then fail $ "failed to execute search: " ++ (rvToStr rv)
        else return objectsHandles


_findObjectsFinalEx :: Session -> IO ()
_findObjectsFinalEx (Session sessionHandle functionListPtr) = do
    rv <- findObjectsFinal' functionListPtr sessionHandle
    if rv /= 0
        then fail $ "failed to finalize search: " ++ (rvToStr rv)
        else return ()


findObjects :: Session -> [Attribute] -> IO [ObjectHandle]
findObjects session attribs = do
    _findObjectsInitEx session attribs
    finally (_findObjectsEx session) (_findObjectsFinalEx session)


generateKeyPair :: Session -> Int -> [Attribute] -> [Attribute] -> IO (ObjectHandle, ObjectHandle)
generateKeyPair (Session sessionHandle functionListPtr) mechType pubKeyAttrs privKeyAttrs = do
    (rv, pubKeyHandle, privKeyHandle) <- _generateKeyPair functionListPtr sessionHandle mechType pubKeyAttrs privKeyAttrs
    if rv /= 0
        then fail $ "failed to generate key pair: " ++ (rvToStr rv)
        else return (pubKeyHandle, privKeyHandle)


login :: Session -> UserType -> BU8.ByteString -> IO ()
login (Session sessionHandle functionListPtr) userType pin = do
    rv <- _login functionListPtr sessionHandle userType pin
    if rv /= 0
        then fail $ "login failed: " ++ (rvToStr rv)
        else return ()


getMechanismList :: Library -> Int -> Int -> IO [CULong]
getMechanismList (Library _ functionListPtr) slotId maxMechanisms = do
    (rv, types) <- _getMechanismList functionListPtr slotId maxMechanisms
    if rv /= 0
        then fail $ "failed to get list of mechanisms: " ++ (rvToStr rv)
        else return types


getMechanismInfo :: Library -> Int -> Int -> IO MechInfo
getMechanismInfo (Library _ functionListPtr) slotId mechId = do
    (rv, types) <- _getMechanismInfo functionListPtr slotId mechId
    if rv /= 0
        then fail $ "failed to get mechanism information: " ++ (rvToStr rv)
        else return types
