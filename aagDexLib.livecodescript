script "aagDexLib"
constant kFeedFile = "/feed.sqlite"
constant kBypassLocalServer = true

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
   _openFeedDatabase
   
   if not dexIsRunning() then
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
   if pDataA["timestamp"] is empty then 
      put the seconds into pDataA["timestamp"]
   end if
   set the httpHeaders to "content-type: application/json"
   post ArrayToJSON(pDataA) to url "http://localhost:9898/publish"
   if the result is not empty then
      put the result into tError
      dexError "Can't publish content:" && the result && it
      if "tsneterr" is in tError then
         dexError "TSNeterror!!!! Argh, reboot dex server"
      end if
      return "error:" && tError
   else
      return it
   end if
end dexPublish


function dexGet pKeyID
   if kBypassLocalServer then
      return _dexGet(pKeyID)
   end if
   get url ("http://localhost:9898/get?id=" & urlencode(pKeyID))
   if the result is not empty then
      dexError "Can't get content:" && the result && it
      return it
   else
      return jsontoarray(it)
   end if
end dexGet

command dexBroadcast pData
   if the milliseconds - sDataA["last broadcast"] < 500 then
      pass dexBroadcast
   end if
   put the milliseconds into sDataA["last broadcast"]
   set the allowDatagramBroadcasts to true
   open datagram socket to "255.255.255.255:9009"
   write pData to socket "255.255.255.255:9009" with message "_dexUDPFinishedBroadcasting"
end dexBroadcast

command dexAnnounceSelf
   put dexAuthorID() into tA["author"]
   put dexAuthorPublicKey() into tA["public"]
   dexBroadcast ArrayToJSON(tA)
   dexInfo "Broadcast own identity"
end dexAnnounceSelf

on _dexUDPFinishedBroadcasting pSocketID
   close socket pSocketID
end _dexUDPFinishedBroadcasting

command dexRegisterEventCallback pTarget, pCallback
   put pCallback into sDataA["callbacks"][pTarget]
end dexRegisterEventCallback

command _dexDispatchCallbacks pType, pData
   repeat for each key t in sDataA["callbacks"]
      dispatch sDataA["callbacks"][t] to t with pType, pData
   end repeat
end _dexDispatchCallbacks
   
function dexFeed pAuthor, pSequenceFrom, pLimit
   if kBypassLocalServer then
      return _dexFeed(pAuthor, pSequenceFrom, pLimit)
   end if
   if pAuthor then
      put "author=" & urlencode(pAuthor) into tParams
   end if
   if pSequenceFrom is not empty then 
      put "&sequence_from=" & pSequenceFrom after tParams
   end if
   if pLimit is not empty then 
      put "&limit=" & pLimit after tParams
   end if
   
   get url ("http://localhost:9898/feed?" & tParams)
   if the result is not empty then
      dexError "Can't get feed:" && the result && it
      return the result
   else
      return jsontoarray(it)
   end if
end dexFeed

on dexFeedFilterByType @pFeedA, pType
   repeat for each key k in pFeedA
      if pFeedA[k]["type"] is not pType then
         delete variable pFeedA[k]
      end if
   end repeat
end dexFeedFilterByType


on dexFeedFilterByAuthor @pFeedA, pAuthor
   repeat for each key k in pFeedA
      if pFeedA[k]["author"] is not pAuthor then
         delete variable pFeedA[k]
      end if
   end repeat
end dexFeedFilterByAuthor

function dexFeedFindLatestSequence pFeedA, pAuthor
   put 0 into tMax
   repeat for each key k in pFeedA
      if pFeedA[k]["sequence"] > tMax then
         put pFeedA[k]["sequence"] into tMax
         put k into tKey
      end if
   end repeat
   return pFeedA[tKey]
end dexFeedFindLatestSequence

function dexFindNameForAuthorID pFeedA pAuthorID
   dexFeedFilterByAuthor pFeedA, pAuthorID
   dexFeedFilterByType pFeedA, "about"
   put dexFeedFindLatestSequence(pFeedA, pAuthorID) into tContactA
   if tContactA["content"]["name"] is not empty then
      return tContactA["content"]["name"]
   else
      return pAuthorID
   end if
end dexFindNameForAuthorID

on dexHandshake pSocket
   put sDataA["peers"][pSocket] into tA
   dexGossip tA
end dexHandshake

on dexGossip pPeerA, pAuthorID
   if pAuthorID is empty then
      put pPeerA["author"] into pAuthorID
   end if
   put "?author=" & urlencode(pAuthorID) into tParams
   put "&sequence_from=" & dexLastSequence(pAuthorID) after tParams
   put "&limit=100" after tParams
   put  ("http://"&pPeerA["socket"]&":9898/feed" & tParams) into tURL
   get url tURL
   if the result is not empty then
      dexError "Can't get feed:" && the result && it
      return it
   else
      put jsontoarray(it) into tFeedA
      if tFeedA is an array then
         _importToFeed tFeedA
      else
         dexInfo "no new entry from peer for" && pPeerA["author"]
      end if
   end if
end dexGossip

on dexRefreshAllPeers
   repeat for each key k in sDataA["peers"]
      dexGossip sDataA["peers"][k]
      wait 2 seconds with messages
   end repeat
end dexRefreshAllPeers

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
      accept datagram connections on port 9009 with message "_dexUDPCallback"
      dexInfo "UDP server started on port 9009"
      dexAnnounceSelf
   else
      dexError "Problem starting server:" && the result
   end if
end dexStart

private function _LocalRequest pSocketID
   return "127.0.0.1:" is in pSocketID
end _LocalRequest

on _dexUDPCallback pSocketID, pData
   dexInfo "UDP Datagram arrived from" && pSocketID &":" && pData
   try
      put jsontoarray(pData) into tA
      if tA["author"] is dexAuthorID() then
         pass _dexUDPCallback
      end if
      if tA["author"] is not empty and tA["public"] is not empty then
         set the itemdel to ":"
         put item 1 of pSocketID into tA["socket"]
         put tA into sDataA["peers"][tA["socket"]]
         dexInfo "new peer found" && tA["author"]
         dexHandshake tA["socket"]
         
      end if
   catch m
      dexError "UDP Datagram is not JSON"
   end try
end _dexUDPCallback

on _dexHTTPCallback pSocketID, pRequestA
   dexInfo pRequestA["method"] && pRequestA["resource"] 
   
   put "Content-type: application/json" into tHeaders
   
   switch pRequestA["method"]
      case "GET"
         switch
            case pRequestA["resource"] is "/running"
               httpdResponse pSocketID, 200, "TRUE"
               break
            case pRequestA["resource"] is "/get"
               if pRequestA["parameters"]["id"] is empty then
                  httpdResponse pSocketID, 400, "error: no feed id given"
                  break
               end if
               put _dexGet(pRequestA["parameters"]["id"]) into tA
               httpdResponse pSocketID, 200, ArrayToJSON(tA), tHeaders
               break
            case pRequestA["resource"] is "/feed"
               put _dexFeed(pRequestA["parameters"]["author"], \
                     pRequestA["parameters"]["sequence_from"], \
                     pRequestA["parameters"]["limit"]) into tA
               
               httpdResponse pSocketID, 200, ArrayToJSON(tA), tHeaders
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
               put tDataA["timestamp"] into tClaimedTimestamp
               if tType is empty then
                  httpdResponse pSocketID, 400, "error: can't publish without type"
                  pass _dexHTTPCallback
               end if
               delete variable tDataA["type"]
               delete variable tDataA["timestamp"]
               
               _addToFeed tType, tDataA, tClaimedTimestamp
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
   put url "binfile:feed.sqlite" into url ("binfile:" & dexFolder(kFeedFile))
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

function dexLastSequence pAuthorID
   if pAuthorID is empty then
      put dexAuthorID() into pAuthorID
   end if
   dbOrderBy "sequence desc"
   dbColumns "sequence"
   dbWhere "author", pAuthorID
   put dbGet("feed", sConnectionID) into tA
   if tA is empty then
      return 0
   else
      return tA[1]["sequence"]
   end if
end dexLastSequence

function dexLastMessageID pAuthorID
   if pAuthorID is empty then
      put dexAuthorID() into pAuthorID
   end if
   dbOrderBy "sequence desc"
   dbColumns "key"
   dbWhere "author", pAuthorID
   put dbGet("feed", sConnectionID) into tA
   if tA is empty then
      return empty
   else
      return tA[1]["key"]
   end if
end dexLastMessageID

private function _dexGet pKeyID
   dbWhere "key", pKeyID
   dbLimit 1
   put dbGet("feed", sConnectionID) into tA
   put JSONToArray(tA[1]["content"]) into tA[1]["content"]
   return tA[1]
end _dexGet


private function _dexFeed pAuthorID, pSequenceOffset, pLimit
   if pAuthorID then
      dbWhere "author", pAuthorID
   end if
   if pLimit is not empty then
      dbLimit pLimit
   end if
   if pSequenceOffset is not empty then
      dbWhere "sequence >=", pSequenceOffset
   end if
   dbOrderBy "timestamp"
   
   put dbGet("feed", sConnectionID) into tA
   repeat for each key k in tA
      put JSONToArray(tA[k]["content"]) into tA[k]["content"]
   end repeat
   return tA
end _dexFeed

private command _addToFeed pType, pDataA, pClaimedTimestamp
   local tDataA
   put dexLastSequence() into tSeq
   put dexAuthorID() into tDataA["author"]
   add 1 to tSeq
   put dexLastMessageID() into tDataA["previous"]
   put tSeq into tDataA["sequence"]
   put toLower(pType) into tDataA["type"]
   put pClaimedTimestamp into tDataA["timestamp"]
   put the seconds into tDataA["timestamp_received"]
   put arrayToJson(pDataA) into tDataA["content"]
   put "sha256" into tDataA["hash"]
   
   -- compute signature
   put arrayToJson(tDataA) into tTemp
   put messageDigest(tTemp, "SHA-256") into tHash
   
   encrypt tHash using rsa with private key _dexAuthorPrivateKey()
   if the result is not empty then
      put the result into tError
      dexError "addtofeed error:" && tError
      answer error "Can't add to feed:" && tError
      return "error:" && tError
   end if 
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
   dexAnnounceSelf
   _dexDispatchCallbacks "afterAddToFeed"
   return tDataA["key"]   
end _addToFeed

function dexFeedHasKey pKey
   dbWhere "key", pKey
   dbLimit 1
   dbColumns "key"
   put dbGet("feed", sConnectionID) into tA
   if tA[1]["key"] is pKey then
      return true
   else
      return false
   end if
end dexFeedHasKey

on _importToFeed pFeedA
   _dexDispatchCallbacks "beforeImportFeed"
   repeat for each key k in pFeedA
      put pFeedA[k] into tA
      if tA["key"] is empty then
         next repeat
      end if
      if dexFeedHasKey(tA["key"]) then
         next repeat
      end if
      put arraytojson(tA["content"]) into tA["content"]
      put the seconds into tA["timestamp_received"]
      get dbInsert("feed", tA, sConnectionID)
      if it is not 1 then
         dexError "feederr: could not insert new entry:" && it
      else
         dexInfo "imported entry" && tA["key"]
      end if
   end repeat
   _dexDispatchCallbacks "afterImportFeed"
   --dexAnnounceSelf
end _importToFeed
