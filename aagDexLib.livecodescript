script "aagDexLib"
constant kFeedFile = "/feed.sqlite"

local sConnectionID
local sDataA

on libraryStack
   if the target is not me then 
      pass libraryStack
   end if
   
   
   put the defaultfolder into tDF
   set the itemdel to "/"
   set the defaultfolder to item 1 to -2 of the effective filename of this stack
   start using stack "aagDBLib.livecode"
   
   _checkSetup
   _loadIdentity
   
   if not dexIsRunning() then
      _openFeedDatabase
      dexStart
   end if
   set the defaultfolder to tDF

end libraryStack

--> Logging routines
on dexLog pMsg
   put (the short date && the short time && "--" && pMsg & crlf) after url ("binfile:" & dexFolder("/dex.log"))
end dexLog

on dexInfo pMsg
   dexLog "[INFO]" && pMsg
end dexInfo

on dexError pMsg
   dexLog "[ERROR]" && pMsg
end dexError

--> DEX Routines

function dexIsRunning
   get url "http://localhost:9898/running"
   if it is "TRUE" then
      dexInfo "Local Dex server is running."
      return true
   else
      dexInfo "Local Dex server NOT running."
      return false
   end if
end dexIsRunning

command dexPublish pType, pDataA
   put pType into pDataA["type"]
   set the httpHeaders to "content-type: application/json"
   post ArrayToJSON(pDataA) to url "http://localhost:9898/publish"
   if the result is not empty then
      dexError "Can't publish content:" && the result && it
      return it
   else
      return it
   end if
end dexPublish

function dexFolder pPath
   if pPath is empty then
      return the home folder & "/.dex_store"
   else
      return the home folder & "/.dex_store" & pPath
   end if
end dexFolder

command dexStart
   httpdStart "_dexHTTPCallback", 9898, "Dex Server"
   if the result is empty and it is 9898 then
      dexInfo "Server started on port 9898."
   else
      dexError "Problem starting server:" && the result
   end if
end dexStart

private function _LocalRequest pSocketID
   return "127.0.0.1:" is in pSocketID
end _LocalRequest

on _dexHTTPCallback pSocketID, pRequestA
   dexInfo pRequestA["method"] && pRequestA["resource"] 
   
   switch pRequestA["method"]
      case "GET"
         switch
            case pRequestA["resource"] is "/running"
               httpdResponse pSocketID, 200, "TRUE"
               break
            case pRequestA["resource"] is "/get"
               if pRequestA["parameters"]["id"] is empty then
                  httpdResponse pSocketID, 400, "error: no feed id given"
               end if
               put dexGet(pRequestA["parameters"]["id"]) into tA
               httpdResponse pSocketID, 200, ArrayToJSON(tA)
               break
         end switch
         break
      case "POST"
         switch
            case _LocalRequest(pSocketID) and pRequestA["resource"] is "/publish"
               if pRequestA["content"] is empty then
                  httpdResponse pSocketID, 400, "error: can't publish without content"
                  pass _dexHTTPCallback
               end if
               try
                  put JSONToArray(pRequestA["content"]) into tDataA
               catch n
                  httpdResponse pSocketID, 400, "error: can't publish, content not json"
                  pass _dexHTTPCallback
               end try
               put tDataA["type"] into tType
               if tType is empty then
                  httpdResponse pSocketID, 400, "error: can't publish without type"
                  pass _dexHTTPCallback
               end if
               delete variable tDataA["type"]
               
               _addToFeed tType, tDataA
               httpdResponse pSocketID, 200, the result
               break
         end switch
         
         break
   end switch
   httpdResponse pSocketID, 404, "resource not found"
end _dexHTTPCallback

private command _checkSetup
   _checkFolders
   _checkSanity
end _checkSetup

private command _checkFolders
   if there is not a folder dexFolder() then
      create folder dexFolder()
   end if
end _checkFolders

private command _checkSanity
   if there is not a file dexFolder(kFeedFile) then
      _createDatabase
   end if
   
   if there is not a file dexFolder("/secret.json")  then
      _createIdentity
   end if 
end _checkSanity

private command _createDatabase
   put the defaultFolder into tDF
   set the itemdel to "/"
   set the defaultFolder to item 1 to -2 of the effective filename of this stack
   revCopyFile "feed.sqlite", dexFolder(kFeedFile)
   set the defaultFolder to tDF
end _createDatabase

private command _triggerError pErr
   answer error pErr
end _triggerError

private command _loadIdentity
   if there is a file dexFolder("/secret.json") then
      put url ("binfile:" & dexFolder("/secret.json")) into tTemp
      put jsonToArray(tTemp) into sDataA["identity"]
      if sDataA["identity"]["public"] is empty then
         throw "keyerr: public key broken in secret.json"
      end if
      if sDataA["identity"]["private"] is empty then
         throw "keyerr: private key broken in secret.json"
      end if
   else
      throw "keyerr: no secret.json found."
   end if
end _loadIdentity

private command _createIdentity pPublicKeyPath, pPrivateKeyPath
   -- secret not found, try to load from SSH
   if pPublicKeyPath is empty then
      put the home folder & "/.ssh/id_rsa.pub" into pPublicKeyPath
   end if
   
   if pPrivateKeyPath is empty then
      put the home folder & "/.ssh/id_rsa" into pPrivateKeyPath
   end if
   
   if there is not a file pPublicKeyPath then
      throw "keyerr: ssh public key not found"
   end if
   
   if there is not a file pPrivateKeyPath then
      throw "keyerr: private key not found"
   end if
   
   put url ("binfile:" & pPublicKeyPath) into sDataA["identity"]["public"]
   put url ("binfile:" & pPrivateKeyPath) into sDataA["identity"]["private"]
   
   put arrayToJson(sDataA["identity"]) into url ("binfile:" & dexFolder("/secret.json"))
end _createIdentity

--> Feed routines

private command _openFeedDatabase
   get revOpenDatabase("sqlite", dexFolder(kFeedFile),,,)
   if it is a number then
      put it into sConnectionID
   else
      answer error it
   end if
end _openFeedDatabase

function dexAuthorID
   set the itemdel to " "
   put item -1 of sDataA["identity"]["public"] into tTemp
   put messageAuthenticationCode(tTemp, sDataA["identity"]["public"], "HMAC-SHA-256") into tHash
   return "@" & base64encode(tHash) & ".sha256"
end dexAuthorID

function dexAuthorPublicKey
   return sDataA["identity"]["public"]
end dexAuthorPublicKey

private function _dexAuthorPrivateKey
   return sDataA["identity"]["private"]
end _dexAuthorPrivateKey

function dexLastSequence
   dbOrderBy "sequence desc"
   dbColumns "sequence"
   dbWhere "author", dexAuthorID()
   put dbGet("feed", sConnectionID) into tA
   if tA is empty then
      return 0
   else
      return tA[1]["sequence"]
   end if
end dexLastSequence

function dexLastMessageID
   dbOrderBy "sequence desc"
   dbColumns "key"
   dbWhere "author", dexAuthorID()
   put dbGet("feed", sConnectionID) into tA
   if tA is empty then
      return empty
   else
      return tA[1]["key"]
   end if
end dexLastMessageID

function dexGet pKeyID
   dbWhere "key", pKeyID
   dbLimit 1
   put dbGet("feed", sConnectionID) into tA
   put JSONToArray(tA[1]["content"]) into tA[1]["content"]
   return tA[1]
end dexGet

private command _addToFeed pType, pDataA
   local tDataA
   put dexLastSequence() into tSeq
   put dexAuthorID() into tDataA["author"]
   add 1 to tSeq
   put dexLastMessageID() into tDataA["previous"]
   put tSeq into tDataA["sequence"]
   put toLower(pType) into tDataA["type"]
   put the milliseconds into tDataA["timestamp"]
   put the milliseconds into tDataA["timestamp_received"]
   put arrayToJson(pDataA) into tDataA["content"]
   put "sha256" into tDataA["hash"]
   
   -- compute signature
   put arrayToJson(tDataA) into tTemp
   encrypt tTemp using rsa with private key _dexAuthorPrivateKey() 
   put it into tHash
   put base64Encode(tHash) into tDataA["signature"]
   
   -- compute final part which is the key
   put arrayToJson(tDataA) into tTemp
   put dexAuthorPublicKey() into tKey
   put messageAuthenticationCode(tTemp, tKey, "HMAC-SHA-256") into tHash
   put "%" & base64encode(tHash) & ".sha256" into tDataA["key"]
   
   -- add to feed
   get dbInsert("feed", tDataA, sConnectionID)
   if it is not 1 then
      throw "feederr: could not insert new entry:" && it
   end if
   return tDataA["key"]   
end _addToFeed
