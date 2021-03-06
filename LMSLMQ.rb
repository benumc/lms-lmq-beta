#!/usr/bin/env ruby
# encoding: utf-8

require 'logger'
require 'socket'
require 'net/http'
require 'uri'
require "open-uri"
#require 'open_uri_redirections'
require 'json'
require 'tempfile'
require 'base64'

$SqueezeboxServerIP = nil
$SqueezeboxServerPort = 9000

$Head = "HTTP/1.1 200 OK\r\nServer: Logitech Media Server\r\nContent-Length: 0\r\nContent-Type: application/json"
$NotFound = "HTTP/1.1 404 Not Found\r\n\r\n"

$blockSize = 1024
$server = TCPServer.open(9000)
$menuBuffer = {}
$imageCache = []
$cachePath = "/tmp/lmslmq/"

$localIP = ""

$localDirectory = File.expand_path(File.dirname(__FILE__))
#"http://#{IPSocket.getaddress(Socket.gethostname)}:9000/"
$uidHash = {}

$artLookup = {}

def LoadPlugin(pNm)
  if pNm.length > 0
    begin
      Object.const_get(pNm)
    rescue
      #puts "Loading #{pNm}"
      begin
        f = File.expand_path(File.dirname(__FILE__)) + '/' + pNm
        require f
      rescue
        #puts $!, $@
        #puts "To unstable to continue without required plugins. Aborting"
      end
    end
  end
end

def GetPlugins()
  Dir["#{ File.expand_path(File.dirname(__FILE__))}/plugins/**/*.rb"].each { |f| require(f) }
rescue
  puts $!, $@
end

def ReadFromSavant(local)
  data = local.recv($blockSize)
  head,msg = data.split("\r\n\r\n")
  msg ||= ""
  iContent = /Content-Length: (\d+)/.match(data)
  if iContent && $1.to_i > msg.length
    while $1.to_i > msg.length
      msg << local.recv($1.to_i)
    end
  end
  return head,msg
rescue
  #puts $!, $@
  return nil
end

def GetSavantReply(body)
  body = JSON.generate(body)
  #puts "LMS Reply:\n#{body}\n\n"
  head = $Head.sub(/Content-Length: \d+/,"Content-Length: #{body.length}")
  return "#{head}\r\n\r\n#{body}"
rescue 
  return body
end

def EmptyBody
  b = {
    "params"=>[
      "",
      [
        "menu",
        "0",
        "999999999999999",
        "item_id:0"
      ]
    ],
    "method"=>"slim.request",
    "result"=>{
    "item_loop"=>[]
    }
  }
  return b
end

def MetaConnect(req)
  body = []
  case req
  when "/meta/handshake"
    body[0] = {
      "clientId"=>"ab5c9411",
      "supportedConnectionTypes"=>["long-polling","streaming"],
      "version"=>"1.0",
      "channel"=>"/meta/handshake",
      "advice"=>{"timeout"=>60000,"interval"=>0,"reconnect"=>"retry"},
      "successful"=>true
    }
  when "/meta/connect"
    body[0] = {
      "timestamp"=>Time.now.inspect,
      "clientId"=>"ab5c9411",
      "channel"=>"/meta/connect",
      "advice"=>{"interval"=>0},
      "successful"=>true
    }
  when "/meta/subscribe"
    body[0] = {
      "clientId"=>"ab5c9411",
      "channel"=>"/meta/subscribe",
      "subscription"=>"/ab5c9411/**",
      "successful"=>true
    }
  end
  return body
end

def ServerStatus()
  #I'm fairly sure savant confirms that the response is valid json and then ignores it.
  #Haven't taken the time to test it.
  return {
    "params"=>["",["serverstatus","0","999"]],
    "method"=>"slim.request",
    "id"=>"1",
    "result"=>{
      "other player count"=>0,
      "info total albums"=>0,
      "player count"=>1,
      "version"=>"7.7.4",
      "players_loop"=>[{
        "seq_no"=>0,
        "playerid"=>"",
        "displaytype"=>"none",
        "connected"=>1,
        "ip"=>"",
        "model"=>"squeezelite",
        "name"=>"Movie Player",
        "uuid"=>nil,
        "isplayer"=>1,
        "canpoweroff"=>1,
        "power"=>"1"
        }],
        "uuid"=>"ac4c8c61-92dc-4c08-ab93-0df4f1dd72e3",
        "sn player count"=>0,
        "info total artists"=>0,
        "info total songs"=>0,
        "lastscan"=>"1416161452",
        "info total genres"=>0
        }
      }
end

def CreateTopMenu(hostname,menuArray)
  body = {
    "params"=>[hostname,["menu","0","500","direct:1"]],
    "method"=>"slim.request",
    "result"=>{"item_loop"=>[]}}
  return body unless menuArray
  menuArray.each do |i|
    if i[:iInput]
      
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "actions"=> {
          "go"=> {
            "params"=> {
              "search"=> "__TAGGEDINPUT__",
              "menu"=> i[:id]
            },
            "cmd"=> ["cmd:#{i[:cmd]}"]
          }
        },
        "window"=> {
          "text"=> i[:text]
        },
        "input"=> {
          "len"=> 1,
          "processingPopup"=> {
            "text"=> "Searching..."
          },
        },
        "text"=> i[:text],
        "weight"=> 110,
        "node"=> "home",
        "id"=> i[:id]
      }
    else
      a = i[:icon] 
      i[:icon] = $localIP + a if a && a.length > 1
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "actions"=>{"go"=>{
          "params"=>{:id=>i[:id],:args=>i[:args]},:cmd=>["cmd:#{i[:cmd]}"]
          }},
        "window"=>{"icon-id"=>i[:icon]},
        "node"=>"home",
        "text"=>i[:text]
        }
    end
  end  
#puts JSON.pretty_generate(body)
  return body
end

def CreateMenu(hostname,menuArray)
  body = {
    "params"=>["",["menu","0","999999999999999"]],
    "method"=>"slim.request",
    "result"=>{  
      "base"=>{  
        "actions"=>{
          "go"=>{  
            "params"=>{},
            "itemsParams"=>"params"
          },
          "more"=>{  
            "params"=>{},
            "itemsParams"=>"params",
            "window"=>{  
              "isContextMenu"=>1
            }
          }
        }
      },
      "item_loop"=>[]}}
  return body unless menuArray.respond_to?('each')
  menuArray.each do |i|
    if i[:iInput]
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "actions"=> {
          "go"=> {
            "params"=> {
              "search"=> "__TAGGEDINPUT__",
              "id"=>i[:id],
              "menu"=> i[:id]
            },
            "cmd"=> ["cmd:#{i[:cmd]}"]
          }
        },
        "window"=> {
          "titleStyle"=> "album"
        },
        "input"=> {
          "len"=> 1,
          "processingPopup"=> {
            "text"=> "Searching..."
          },
        },
        "text"=> i[:text],
        "weight"=> 110,
        "id"=> "opmlsearch"
      }
    else
      a = i[:icon] 
      i[:icon] = $localIP + a if a && a.length > 1
      /([^\(\[]+)(.*)/.match(i[:text])
      i[:text] = "#{$1}\n#{$2}" if $1 && $2
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "params"=>{
          :cmd=>i[:cmd],
          :id=>i[:id],
          :args=>[i[:args]]
        },
        :text=>i[:text]
        }
      body["result"]["item_loop"][body["result"]["item_loop"].length-1][:icon]=i[:icon] if i[:icon]
      body["result"]["item_loop"][body["result"]["item_loop"].length-1][:presetParams]={} if i[:iContext]
    end
    if menuArray.length > 40 && i[:textKey]
      tk = (i[:text].delete("The ")[0] || "").upcase
      body["result"]["item_loop"][body["result"]["item_loop"].length-1][:textkey]=tk
    end
  end
 #puts JSON.pretty_generate(body)
  return body
end

def CreateContextMenu(hostname,menuArray)
  #puts menuArray
  body = {
  "params"=>["",[]],
  "method"=>"slim.request",
  #"result"=>{  
    "result"=>{"item_loop"=>[]}}
  return body unless menuArray
    menuArray.each do |i|
      body["result"]["item_loop"][body["result"]["item_loop"].length] = {
        "actions"=>{"go"=>{
          "params"=>{:id=>i[:id],:args=>i[:args]},"cmd"=>[i[:cmd]]
        }},
        "text"=>i[:text]
        }
    end
    #puts body
  return body
end

def CreateNowPlaying(hostname,menuArray)
  #puts "Create Now Playing:"
  #puts hostname
  #puts JSON.generate(menuArray)
  body = {
  "params"=>["",[]],
  "method"=>"slim.request",
  "result"=>{"item_loop"=>[]}}
  return body unless menuArray
    menuArray.each do |i|
      if i[:iInput]
        h = {
          "actions"=>{
            "do"=>{
              "itemsParams"=>"params",
              "params"=>{
                :search=>"__TAGGEDINPUT__"
              },
              "cmd"=>["cmd:#{i[:cmd]}","id:#{i[:id]}"]
            }
          },
          "input"=>{"len"=>1},
          :text=>i[:text]
        }
        h["icon-id"]=i[:icon] if i[:icon]
      else
        a = i[:args]||""
        h = {
          "params"=>{
            "track_id"=>i[:id],
            "playlist_index"=>i[:id]
          },
          "actions"=>{
            "do"=>{
              "cmd"=>["cmd:#{i[:cmd]}","id:#{i[:id]}"]
            }
          },
          :text=>i[:text]
        }
        h["icon-id"]=i[:icon] if i[:icon]
        body["result"]["playlist_cur_index"]="#{i[:id]}" if i[:current]
      end
      body["result"]["item_loop"] << h
    end
    #puts JSON.generate(body)
  return body
end

def CreateStatus(hostname,statusHash)
  #check cache array for stored image url
  #try to store image to cache and provide index url
  
  body = {}
  
  
  statusHash ||= {:Mode=>"stop"}
  
  if statusHash[:Artwork]
    $artLookup[statusHash[:Id]] = statusHash[:Artwork]
  end
  
  statusHash[:Info] = statusHash[:Info].to_a || []
  statusHash[:Info].each do |e|
    e.gsub!(/\P{ASCII}/, '') if e
  end
  body["id"] = statusHash[:Id] || ""
  body["result"] = {
    "seq_no"=>0,
    "mixer volume"=>statusHash[:Volume]||0,
    "mixer muting"=>statusHash[:Mute]||0,
    "player_name"=>"player",
    "playlist_tracks"=>1,
    "player_connected"=>1,
    "playlist_tracks"=>1,
    "time"=>statusHash[:Time] || 0,
    "mode"=>statusHash[:Mode] || "pause",
    "signalstrength"=>0,
    "playlist_timestamp"=>1,
    "remote"=>1,
    "rate"=>1,
    "can_seek"=>1,
    "power"=>1,
    "playlist repeat"=>statusHash[:Repeat]||0,
    "duration"=>statusHash[:Duration] || 0,
    "playlist mode"=>"on",
    "player_ip"=>"",
    "playlist_cur_index"=>"1",
    "playlist_loop"=>[{
      "playlist index"=>1,
      "id"=>statusHash[:Id] || "",
      "title"=>statusHash[:Info][0]||"",
      "coverid"=>statusHash[:Id]||"",
      "artist"=>statusHash[:Info][1]||"",
      "album"=>statusHash[:Info][2]||"",
      "duration"=>statusHash[:Duration] || 0,
      "tracknum"=>"1",
      #"year"=>player[:NowPlaying]["ProductionYear"],
      #"bitrate"=>player[:NowPlaying]["MediaStreams"][0]["BitRate"],
      #"url"=>player[:NowPlaying]["Path"],
      #"type"=>player[:NowPlaying]["Type"],
      "artwork_url"=>statusHash[:Artwork]||""
    }],
    "remoteMeta"=>{
      "id"=>statusHash[:Id]||"",
      "title"=>statusHash[:Info][0]||"",
      "coverid"=>statusHash[:Id]||"",
      "artist"=>statusHash[:Info][1]||"",
      "album"=>statusHash[:Info][1]||"",
      "duration"=>statusHash[:Duration]||0,
      "tracknum"=>"1",
      #"year"=>player[:NowPlaying]["ProductionYear"],
      #"bitrate"=>player[:NowPlaying]["MediaStreams"][0]["BitRate"],
      #"url"=>player[:NowPlaying]["Path"],
      #"type"=>player[:NowPlaying]["Type"],
      "artwork_url"=>statusHash[:Artwork]||""
    },
    "playlist shuffle"=>statusHash[:Shuffle]||0,
    "current_title"=>statusHash[:Info][0]||"",
    "player_ip"=>""
  }
  #puts JSON.pretty_generate(body)
  return body
end

def ServerPost(h,msg)
    p = true unless msg.include?('"status","-","1"')
    sock = TCPSocket.open($SqueezeboxServerIP,$SqueezeboxServerPort)
    h.gsub!(/Content-Length: \d+/,"Content-Length: #{msg.length}")
    
    #puts "Savant Request:\n#{msg}\n\n" if p
    
    sock.write("#{h}\r\n\r\n#{msg}")
    h = sock.gets("\r\n\r\n")
    /Content-Length: ([^\r\n]+)\r\n/.match(h)
    l = $1.to_i
    r = ''
    
    while l > r.length
        r << sock.read(l - r.length)
    end
    
    #puts "Squeeze Response:\n#{r}\n\n" if p
      
    return "#{h}#{r}"
  rescue
    puts $!, $@
    return nil
end

def SavantRequest(req,head,msg)
  hstnm = req["params"][0]
  hostname = {}
  #if $uidHash[hstnm]
  #  hostname = $uidHash[hstnm]
  #  pNm = (hostname["plugin"]||"").capitalize
  #else
  if hstnm.include?("cmd:playerinfo")
    hstnm.scan(/([^:]+):([^,]+),?/).map {|x| hostname[x[0]]=x[1]}
    pNm = (hostname["plugin"]||"").capitalize
    unless pNm.to_s == ""
      $uidHash[hostname["name"].downcase] = hostname
      return EmptyBody()
    else
      return EmptyBody()
    end
  elsif $uidHash[hstnm]
    hostname = $uidHash[hstnm]
    pNm = (hostname["plugin"]||"").capitalize
  elsif $SqueezeboxServerIP
    #puts "Possibly need to forward to squeezebox server"
    #puts req
    msg.gsub!("999999999999999","1000") if head.include? "POST"
    msg.gsub!("\"time\": \"\([^ ]*\)\",","\"time\": \1,")
    r = ServerPost(head,msg) 
    return r || EmptyBody()
  else
    return EmptyBody()
  end
  #end
  #puts "Hostname: #{hostname}"
  #LoadPlugin(pNm)
  #puts req unless req["params"][1][0] == "status"
  req = req["params"][1]
  case 
  when req == ["version","?"] #fixed response not sure how much is needed
    body = {
    "params"=>["",["version","?"]],
    "method"=>"slim.request",
    "id"=>"1",
    "result"=>{"_version"=>"7.7.4"}
    }
  when req == ["serverstatus","0","999"]
    body = ServerStatus()
  when req.include?("xmlBrowseInterimCM:1") #Request for context popover menu
    cmd = "ContextMenu"
    body = CreateContextMenu(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req == ["menu","0","500","direct:1"] #top menu request.
    cmd = "TopMenu"
    body = CreateTopMenu(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req[0] == "status" && req[1] == "-" #Request for current title info and art
    cmd = "Status"
    body = CreateStatus(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req[0] == "status" && req[1] == "0" #Request for playlist or extended now playing options
    cmd = "NowPlaying"
    body = CreateNowPlaying(hostname,Object.const_get(pNm).SavantRequest(hostname,cmd,req))
  when req[0] == "playlist" && req[1] == "play"
    cmd = "AutoStart"
  when req[0] == "playlist" && req[1] == "jump"
    cmd = "PlaylistJump"
    req[2] = "id:#{req[2]}"
  when req[0] == "time"
    req[1] = "time:#{req[1]}"
    cmd = "SkipToTime"
  when req[0] == "play"
    cmd = "TransportPlay"
  when req[0] == "pause"
    cmd = "TransportPause"
  when req[0] == "stop" || (req[0] == "playlist" && req[1] == "clear")
    cmd = "TransportStop"
  when req[0] == "button" && req[1] == "scan_up"
    cmd = "TransportFastReverse"
  when req[0] == "button" && req[1] == "scan_down"
    cmd = "TransportFastForward"
  when req[0] == "button" && req[1] == "jump_rew"
    cmd = "TransportSkipReverse"
  when req[0] == "button" && req[1] == "jump_fwd"
    cmd = "TransportSkipForward"
  when req[0] == "button" && req[1] == "repeat_on"
    cmd = "TransportRepeatOn"
  when req[0] == "button" && req[1] == "repeat_toggle"
    cmd = "TransportRepeatToggle"
  when req[0] == "button" && req[1] == "repeat_off"
    cmd = "TransportRepeatOff"
  when req[0] == "button" && req[1] == "shuffle_on"
    cmd = "TransportShuffleOn"
  when req[0] == "button" && req[1] == "shuffle_off"
    cmd = "TransportShuffleOff"
  when req[0] == "button" && req[1] == "shuffle_toggle"
    cmd = "TransportShuffleToggle"
  when req[0] == "button" && req[1] == "play"
    cmd = "TransportPlay"
  when req[0] == "button" && req[1] == "pause"
    cmd = "TransportPause"
  when req[0] == "button" && req[1] == "menu"
    cmd = "TransportMenu"
  when req[0] == "button" && req[1] == "up"
    cmd = "TransportUp"
  when req[0] == "button" && req[1] == "down"
    cmd = "TransportDown"
  when req[0] == "button" && req[1] == "left"
    cmd = "TransportLeft"
  when req[0] == "button" && req[1] == "right"
    cmd = "TransportRight"
  when req[0] == "button" && req[1] == "select"
    cmd = "TransportSelect"
  when req[0] == "search" || req[0] == "Search"
    cmd = "Search"
  when req[0] == "input" || req[0] == "Input"
    cmd = "Input"
  when req[0] == "power" && req[1] == "0"
    cmd = "PowerOff"
  when req[0] == "power" && req[1] == "1"
    cmd = "PowerOn"
  when req[0] == "mixer" && req[1] == "volume" && req[2] == "+1"
    cmd = "VolumeUp"
  when req[0] == "mixer" && req[1] == "volume" && req[2] == "-1"
    cmd = "VolumeDown"
  when req[0] == "mixer" && req[1] == "volume"
    req[1] = req[1]+":"+req[2]
    cmd = "SetVolume"
  when req[0] == "mixer" && req[1] == "muting" && req[2] == "1"
    cmd = "MuteOn"
  when req[0] == "mixer" && req[1] == "muting" && req[2] == "0"
    cmd = "MuteOff"
  when req.find {|e| /cmd:([^"]+)/ =~ e} # if command is defined by plugin
    cmd = $1
  else
   #puts "Request ignored:\n#{req}" 
  end
  if cmd && pNm && hostname && !body
    begin
      rep = Object.const_get(pNm).SavantRequest(hostname,cmd,req) unless body
    rescue 
      puts $!, $@
      #abort
    end
    body = CreateMenu(hostname,rep) unless rep.nil?
  end
  body ||= EmptyBody()
  return body
end

def GetArtwork(request)
  content = ""
  response = ""
  imgType = ""
  if request.match(/GET \/([^ ]+) HTTP\/1\.0?1?/)
    request = $1.sub("/"+$localIP,"")
  end
  
  request = request[/music\/([^\/]+?)\/cover\.jpg/,1] || request
  request = $artLookup[request] if $artLookup[request]
  
  pluginIcon = request[/(plugins\/[^\/]+\/icons\/.+)/,1]
  
  if pluginIcon
    f = $localDirectory+"/"+URI.decode(request)
    if File.file?(f+".jpg")
      imgType = "jpg"
      content = File.open(f+".jpg","rb").read
    elsif File.file?(f+".png")
      imgType = "png"
      content = File.open(f+".png","rb").read      
    end
  elsif request.include?("http")
    
    file = Tempfile.new('lmq')
    file.write open(request).read
    file.close
    content = File.open(file.path,"rb").read
    file.unlink
    imgType = "jpg"
  end
  if imgType == ""
    response = $NotFound
  else
    response = "HTTP/1.1 200 OK\r\nContent-Type: image/#{imgType}\r\nContent-Length: #{content.length}\r\n\r\n#{content}"
  end
  return response
rescue
  puts $!, $@
end

def ConnThread(local)
  head,msg = ReadFromSavant(local)
  #puts "Head: #{head},Message: #{msg}"
  #puts "Savant Request:\n#{head}\n#{msg}\n\n"
  if msg && msg.length > 4 && head.include?("json")
    if $localIP == "" 
      $localIP = "http://#{head[/Host: ([^\r\n]+)/,1]}/"
      puts "Local IP address: #{$localIP}"
    end
    begin
      req = JSON.parse(msg)
    rescue
      #puts "****************"
      #puts "JSON Parse Error"
      #puts msg
      #puts $!, $@
      #puts "****************"
      r = $NotFound
    end
    case req
    when Array #some of the setup requests are arrays not
      body = MetaConnect(req[0]["channel"])
      #Netplayaudio.NetplayConnect(head,msg)
    when Hash
      body = SavantRequest(req,head,msg)
    else
     puts "Unexpected result: #{req}"
    end
     #puts "Reply#{body}"
     reply = GetSavantReply(body)
    begin
      local.write(reply)
      local.close
    rescue 
      puts $!, $@
      puts "Reply failed. Savant Closed Socket. Continuing..."
    end
  else #savant could be asking for artwork, try and facilitate...
    #puts "Savant Request:\n#{head}\n#{msg}\n\n"
    r = GetArtwork(head)
    begin
      #puts "Responese: #{r.inspect}"
      local.write(r)
      local.close
    rescue
      puts $!, $@
      puts "Attempted to write: #{r}."
      puts "Write failed. Savant Closed Socket. Continuing..."
    end
  end
end

Thread.abort_on_exception = true #set false to increase longevity 

puts "Loading Plugins"

GetPlugins()

puts "Waiting for connection from Savant on port 9000. #{$server}"
loop do #Each savant request creates a new thread
  Thread.start($server.accept) { |local| ConnThread(local) }
end
