
require 'socket'
require 'json'
require 'uri'
require 'open-uri'
require 'cgi'


module Heos
  
  extend self
  
  #puts "Heos Loaded!"
@@heosServerAddress = ""
@@playerDB = {}
@@recBuffer = []
@@server = false
@@sock = false

def GetServerAddress
  @@server = true
  addr = ['239.255.255.250', 1900]# broadcast address
  udp = UDPSocket.new
  udp.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, true)
  data = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:schemas-denon-com:device:ACT-Denon:1\r\n"
  udp.send(data, 0, addr[0], addr[1])
  data,address = udp.recvfrom(1024)
  @@heosServerAddress = address[2]
  udp.close
  @@sock = TCPSocket.open(@@heosServerAddress,1255)
  #puts @@heosServerAddress
rescue
  #puts "Could Not Connect to Server. Retry"
  sleep(1)
  retry
end

#Thread.abort_on_exception = true
def MaintainSocket
  th = Thread.new do
    #puts "Start Socket"
    loop do
      begin
        #r = JSON.parse(@@sock.gets)
        GetServerAddress() unless @@server
        sleep(1) until @@sock
        r = @@sock.gets
        #puts r
        #c = r["heos"]["command"]
        #m = r["heos"]["message"]
        #m ||= ""
        if r.include?("command under process")
          #ignore and continue
        elsif r.include?('"command": "event/')
          #puts "Found Event: #{r}"
          r = JSON.parse(r)
          c = r["heos"]["command"]
          m = Hash[(r["heos"]["message"]||"").split("&").map{|v|v.split("=")}]
          @@playerDB.each{|k,v| m["name"] = k if v[:HeosId] == m["pid"].to_i}
          c = c.split("/")[1]
          send(c,m)
        else
          #puts "Received From Heos: #{r}"
          @@recBuffer << r
        end
      rescue
        #puts $!, $@
        GetServerAddress()
        retry
      end
    end
  end
  rescue
    @@sock = nil
    @@server = nil
end

def SendToPlayer(msg)
  #puts "Sending Message: heos://#{msg}"
  GetServerAddress() unless @@server
  sleep(1) until @@sock
  @@sock.puts("heos://#{msg}")
  loop do
    #puts @@recBuffer
    i = @@recBuffer.index{|s| s.include?(msg.split('?')[0])}
    if i
      r = JSON.parse(@@recBuffer[i])
      #puts "Match Found #{i}: #{r}"
      @@recBuffer.delete_at(i)
      return r
      break
    end
    #c = ""
    #m = ""
    #until c == msg.split('?')[0] && m !~ /command under process/
    #  r = JSON.parse(@@sock.gets)
    #  c = r["heos"]["command"]
    #  m = r["heos"]["message"]
    #end
    sleep(0.5)
  end
rescue
  #puts $!, $@
  sleep(1)
  retry
end

def Login(un,pw)
  loop do
    r = SendToPlayer("system/sign_in?un=#{un}&pw=#{pw}")
    break if r["heos"]["result"]=="success"
    sleep(1)
  end
  #r = SendToPlayer("system/check_account")
  #while r["heos"]["message"] == "signed_out"
  #  sleep(1)
  #  r = SendToPlayer("system/check_account")
  #end
  return true
end

def GetPlayerId(devName)
  r = SendToPlayer("players/get_players")
  if r
    r["payload"].each do |s|
      if s["name"].downcase == devName
        return s["pid"]
      end
    end
  end
  return nil
end

  #Server Command Handling Below

def Play(playerId,titleId,startAtSecs,audioIndex)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def Pause(playerId)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def Stop(playerId)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def StandardBrowse(mId) #implement count / range   
  #puts "Get Menu From Heos :\n#{mId}"
  m = mId.split("&cid=")
  if m[1] && m[1].include?("http")
    url = URI.decode(URI.decode(URI.decode(m[1])))
    mId = "#{m[0]}&cid=#{CGI.escape(url)}"
    rt = JSON.parse(open(url).read)["body"]
    if rt
      n = []
      rt.each{|h| h["children"].each{|h1| n << h1} if h["children"]}
      j = Hash[n.map{|e| [e["text"],e["image"]] }] 
    end
  end
  r = SendToPlayer("browse/browse?#{mId}")
  #puts "Received Menu For Parsing :\n#{r}"
  b = []
  if r
    r["payload"].each do |s|
      s["name"] = URI.decode(s["name"])
      if s["sid"]
        id = "sid=#{s["sid"]}"
      elsif s["mid"]
        id = "#{mId.split("&cid=")[0]}&mid=#{s["mid"]}"
      else
        id = "#{mId.split("&cid=")[0]}&cid=#{s["cid"]}"
      end
      #puts s
      if mId == "sid=3" #override tunein main menu icons with local ones
        img = "plugins/heos/icons/tunein_#{s["name"].downcase.gsub(" ","+")}"
      else
        img = s["image_url"] || s["image_uri"]
        if s["image_url"] == "" && j
          img = j[s["name"]] || img
        end
        if img.include?("opml.radiotime.com")
          img = ""
        end
      end
      #puts img
      h = {}
      h[:id] = id
      h[:cmd] = s["type"]
      h[:text] = s["name"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})
      h[:icon] = img if img.length > 0
      h[:iContext] = true if s["playable"] == "yes"
      b << h
    end
  end
  #puts "Heos Menu :\n#{b}"
  return b
end

#Savant Request Handling Below********************

def SavantRequest(hostname,cmd,req)
  #puts "Hostname:\n#{hostname}\n\nCommand:\n#{cmd}\n\nRequest:\n#{req}" unless cmd == "Status"
  h = Hash[req.select { |e|  e.include?(":")  }.map {|e| e.split(":",2) if e && e.to_s.include?(":")}]
  unless @@playerDB[hostname["name"]] && @@playerDB[hostname["name"]][:SignedIn]
    
    t = hostname["topmenu"].split(":") if hostname["topmenu"]
    @@playerDB[hostname["name"]] = {
      :SignedIn => Login(hostname["un"],hostname["pw"]),
      :HeosId => GetPlayerId(hostname["name"]),
      :Sources => {},
      :TopMenu => t
    }
    
    sh = {}
    sn = 1
    if hostname["sources"]
      r = SendToPlayer("browse/get_music_sources")
      if s = r["payload"].find {|s| s['name']== "AUX Input"}
        r = SendToPlayer("browse/browse?sid=#{s["sid"]}")
        r["payload"].each do |s|
          rs = SendToPlayer("browse/browse?sid=#{s["sid"]}") || []
          rs["payload"].each do |sr|
            sh[sr["name"].downcase] = "sid=#{s["sid"]}&mid=#{sr["mid"]}"
          end
        end
        hostname["sources"].split(":").each do |s|
          @@playerDB[hostname["name"]][:Sources][sn.to_s] = sh[s]
          sn = sn + 1
        end
      end
    end
    #puts @@playerDB
    
    SendToPlayer("system/register_for_change_events?enable=on")
  end
  return send(cmd,hostname["name"],h["id"],h)
rescue
  return nil
end

def TopMenu(pNm,mId,params)
  r = SendToPlayer("browse/get_music_sources")
  #puts r
  b = []
  if r
    if @@playerDB[pNm][:TopMenu]
      @@playerDB[pNm][:TopMenu].each do |n|
        #puts n.inspect
        if s = r["payload"].find { |s| s['name'].downcase == n }
          #puts n
          b[b.length] = {
            :id =>"sid=#{s["sid"]}",
            :cmd =>s["type"],
            :text =>s["name"],
            :icon =>"plugins/heos/icons/#{s["name"].downcase.gsub(" ","+")}",
            :args =>"browse/get_search_criteria?sid=#{s["sid"]}"
          }
        elsif n == 'queue'
          b[b.length] = {
            :id => 'manage_playing',
            :cmd => 'manage_playing',
            :text => 'Now Playing',
            :icon => 'plugins/heos/icons/playing'
          }
        elsif n == 'groups'
          b[b.length] = {
            :id => 'manage_groups',
            :cmd => 'manage_groups',
            :text => 'Groups',
            :icon =>'plugins/heos/icons/groups'
          }
        elsif n == 'account'
          b[b.length] = {
            :id => 'heos_account',
            :cmd => 'heos_account',
            :text => 'Heos Account',
            :icon => 'plugins/heos/icons/heos+account'
          }
        end
      end
    else
      r["payload"].each do |s|
        #browse/get_search_criteria?sid=#{s}
        b[b.length] = {
          :id =>"sid=#{s["sid"]}",
          :cmd =>s["type"],
          :text =>s["name"],
          :icon =>"plugins/heos/icons/#{s["name"].downcase.gsub(" ","+")}",
          :args =>"browse/get_search_criteria?sid=#{s["sid"]}"
        }
      end
    end
  end
  return b
end

def Status(pNm,mId,params)

  return {} unless @@playerDB[pNm] && @@playerDB[pNm][:HeosId]
  unless @@playerDB[pNm][:PlayState]
    r = SendToPlayer("player/get_play_state?pid=#{@@playerDB[pNm][:HeosId]}")
    @@playerDB[pNm][:PlayState] = r["heos"]["message"].split("state=")[1]
  end
  iSid = 0
  sAlb = ""
  unless @@playerDB[pNm][:Info]
    r = SendToPlayer("player/get_now_playing_media?pid=#{@@playerDB[pNm][:HeosId]}")
    #sh = @@playerDB[pNm][:Shuffle] == 1 ? " SH" : ""
    #re = case @@playerDB[pNm][:Repeat]; when 1; " RS"; when 2; " RA"; else; ""; end
    @@playerDB[pNm][:Info] = []
    @@playerDB[pNm][:Info] << r["payload"]["song"]
    @@playerDB[pNm][:Info] << r["payload"]["artist"]#"[#{sh}#{re}]"
    @@playerDB[pNm][:Info] << r["payload"]["album"]
    @@playerDB[pNm][:Info] << r["payload"]["station"]
    @@playerDB[pNm][:Id] = r["payload"]["mid"]
    @@playerDB[pNm][:Artwork] = r["payload"]["image_uri"] || r["payload"]["image_url"]
    @@playerDB[pNm][:Sid] = r["payload"]["sid"]
    @@playerDB[pNm][:Alb] = r["payload"]["album_id"]
  end
  
  if @@playerDB[pNm][:Artwork].to_s == ''
    r = SendToPlayer("browse/retrieve_metadata?sid=#{@@playerDB[pNm][:Sid]}&cid=#{@@playerDB[pNm][:Alb]}")
    @@playerDB[pNm][:Artwork] = r["payload"][0]["images"][-1]["image_url"] rescue ""
  end
  
  #puts @@playerDB[pNm][:Volume]
  unless @@playerDB[pNm][:Volume]
    r = SendToPlayer("player/get_volume?pid=#{@@playerDB[pNm][:HeosId]}")
    v = r["heos"]["message"].split("level=")[1]
    #puts v
    @@playerDB[pNm][:Volume] = v.to_i
  end
  
  unless @@playerDB[pNm][:Mute]
    r = SendToPlayer("player/get_mute?pid=#{@@playerDB[pNm][:HeosId]}")
    m = 0
    m = 1 if r["heos"]["message"].split("state=")[1] == "on"
    @@playerDB[pNm][:Mute] = m
  end
  
  if @@playerDB[pNm][:Position] && @@playerDB[pNm][:Timestamp]
    if @@playerDB[pNm][:PlayState] == "play"
      time = Time.new - @@playerDB[pNm][:Timestamp] + @@playerDB[pNm][:Position]
    elsif @@playerDB[pNm][:PlayState] == "pause"
      time = @@playerDB[pNm][:Position]
    else
      time = 0
    end
  else
    time = 0
  end
  
  duration = @@playerDB[pNm][:Duration] || 0
  id =  @@playerDB[pNm][:Id] || 0
  i = @@playerDB[pNm][:Info] || [""]
  art = @@playerDB[pNm][:Artwork]
  mode = @@playerDB[pNm][:PlayState] || "stop"
  vol = @@playerDB[pNm][:Volume] || 0
  mute = @@playerDB[pNm][:Mute] || 0
  shuffle = @@playerDB[pNm][:Shuffle] || 0
  repeat = @@playerDB[pNm][:Repeat] || 0
  body = {
      :Mode => mode,
      :Id => id,
      :Time => time,
      :Duration => duration,
      :Info => i.reject { |item| item.nil? || item == '' },
      :Artwork => art,
      :Volume => vol,
      :Mute => mute,
      :Repeat => repeat,
      :Shuffle => shuffle
    }
    #puts body
  return body
end


def ContextMenu(pNm,mId,params)
  #puts "Context"
puts "#{__method__} Debug: MID - #{mId} : Params - #{params}"
  case params["cmd"]
  when "container"
    b = [{:id=>"browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=1",:cmd=>"cmd:queue",:text=>"Play Now"},
         {:id=>"browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=2",:cmd=>"cmd:queue",:text=>"Play Next"},
         {:id=>"browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=3",:cmd=>"cmd:queue",:text=>"Add To Queue"},
         {:id=>"browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=4",:cmd=>"cmd:queue",:text=>"Replace Queue"}]
  #puts b
  when "queue_jump"
    b = [{:id=>"browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=1",:cmd=>"cmd:queue",:text=>"Play Now"},
         {:id=>"browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=2",:cmd=>"cmd:queue",:text=>"Remove  from Queue"}]
   when "station"
     b = [{:id=>"browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=1",:cmd=>"cmd:queue",:text=>"Play Now"}]
  end
  return b
end

def NowPlaying(pNm,mId,params)
#puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
  #"player/get_queue?pid=1&range=0,10"
  
  #r = SendToPlayer("player/get_now_playing_media?pid=#{@@playerDB[pNm][:HeosId]}")
  
  b = []
  r = SendToPlayer("player/get_queue?pid=#{@@playerDB[pNm][:HeosId]}")
  puts r
  if r
    h = {}
    h[:id] = "save"
    h[:cmd] = "queue_save"
    h[:text] = "Save Playlist"
    h[:iInput] = true

    b << h
    r["payload"].each do |s|
      #if s["sid"]
      #  id = "sid=#{s["sid"]}"
      #elsif s["mid"]
      #  id = "#{mId.split("&cid=")[0]}&mid=#{s["mid"]}"
      #else
      #  id = "#{mId.split("&cid=")[0]}&cid=#{s["cid"]}"
      #end
      #puts s
      #img = s["image_url"] || s["image_uri"]
      #if s["image_url"] == "" && j
      #  img = j[s["name"]] || img
      #end
      h = {}
      h[:id] = s["qid"]
      h[:cmd] = "queue_jump"
      h[:text] = "#{s["qid"]}. #{s["song"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})}\n"\
                 "#{s["artist"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})} - "\
                 "#{s["album"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})}"
      #h[:icon] = img if img.length > 0
      h[:iContext] = true
      b << h
    end
  end
  #puts "Now Playing Menu:"
  #puts b
  return b
  rescue
    puts $!, $@
end

def AutoStart(pNm,mId,params)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def SkipToTime(pNm,mId,params)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def TransportPlay(pNm,mId,params)
  SendToPlayer("player/set_play_state?pid=#{@@playerDB[pNm][:HeosId]}&state=play")
  return {}
end

def TransportPause(pNm,mId,params)
  SendToPlayer("player/set_play_state?pid=#{@@playerDB[pNm][:HeosId]}&state=pause")
  return {}
end

def TransportStop(pNm,mId,params)
  SendToPlayer("player/set_play_state?pid=#{@@playerDB[pNm][:HeosId]}&state=stop")
  return {}
end

def TransportFastReverse(pNm,mId,params)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def TransportFastForward(pNm,mId,params)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def TransportSkipReverse(pNm,mId,params)
  SendToPlayer("player/play_previous?pid=#{@@playerDB[pNm][:HeosId]}")
  return {}
end

def TransportSkipForward(pNm,mId,params)
  SendToPlayer("player/play_next?pid=#{@@playerDB[pNm][:HeosId]}")
  return {}
end

def TransportShuffleToggle(pNm,mId,params)
  @@playerDB[pNm][:Shuffle] = (@@playerDB[pNm][:Shuffle] || 0) + 1
  case @@playerDB[pNm][:Shuffle]
  when 1
    s = "on"
  else
    s = "off"
    @@playerDB[pNm][:Shuffle] = 0
  end
  SendToPlayer("player/set_play_mode?pid=#{@@playerDB[pNm][:HeosId]}&shuffle=#{s}")
  return {}
end

def TransportRepeatToggle(pNm,mId,params)
  @@playerDB[pNm][:Repeat] = (@@playerDB[pNm][:Repeat] || 0) + 1
  case @@playerDB[pNm][:Repeat]
  when 1
    r = "on_all"
  when 2
    r = "on_one"
  else
    r = "off"
    @@playerDB[pNm][:Repeat] = 0
  end
  SendToPlayer("player/set_play_mode?pid=#{@@playerDB[pNm][:HeosId]}&repeat=#{r}")
  return {}
end

def PowerOff(pNm,mId,params)
  SendToPlayer("player/set_play_state?pid=#{@@playerDB[pNm][:HeosId]}&state=pause")
  return {}
end

def PowerOn(pNm,mId,params)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def VolumeUp(pNm,mId,params)
  unless @@playerDB[pNm][:Volume]
    r = SendToPlayer("player/get_volume?pid=#{@@playerDB[pNm][:HeosId]}")
    v = r["heos"]["message"].split("level=")[1]
    #puts v
    @@playerDB[pNm][:Volume] = v.to_i - 5
    @@playerDB[pNm][:Volume] = 0 if @@playerDB[pNm][:Volume] < 0
  end
  v = @@playerDB[pNm][:Volume]
  r = SendToPlayer("player/set_volume?pid=#{@@playerDB[pNm][:HeosId]}&level=#{v}")
  if r && r["heos"] && r["heos"]["message"]
    v = r["heos"]["message"].split("level=")[1]
    @@playerDB[pNm][:Volume]=v.to_i
  end
  return {}
end

def VolumeDown(pNm,mId,params)
  unless @@playerDB[pNm][:Volume]
    r = SendToPlayer("player/get_volume?pid=#{@@playerDB[pNm][:HeosId]}")
    v = r["heos"]["message"].split("level=")[1]
    #puts v
    @@playerDB[pNm][:Volume] = v.to_i + 5
    @@playerDB[pNm][:Volume] = 100 if @@playerDB[pNm][:Volume] > 100
  end
  v = @@playerDB[pNm][:Volume]
  r = SendToPlayer("player/set_volume?pid=#{@@playerDB[pNm][:HeosId]}&level=#{v}")
  if r && r["heos"] && r["heos"]["message"]
    v = r["heos"]["message"].split("level=")[1]
    @@playerDB[pNm][:Volume]=v.to_i
  end
  return {}
end

def SetVolume(pNm,mId,params)
  #puts mId
  #puts params
  r = SendToPlayer("player/set_volume?pid=#{@@playerDB[pNm][:HeosId]}&level=#{params["volume"]}")
  if r && r["heos"] && r["heos"]["message"]
    v = r["heos"]["message"].split("level=")[1]
    @@playerDB[pNm][:Volume]=v.to_i
  end
  return {}
end

def MuteOn(pNm,mId,params)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

def MuteOff(pNm,mId,params)
puts "#{__method__} Not Implemented: MID - #{mId} : Params - #{params}"
end

#Plugin defined requests below ********************************

def selectinput(pNm,mId,params)
  SendToPlayer("browse/play_stream?#{params["inputnumber"]}&pid=#{@@playerDB[pNm][:HeosId]}")
  
  return {}
end

def heos_service(pNm,mId,params)
  return StandardBrowse(mId)
end

def music_service(pNm,mId,params)
  menu = StandardBrowse(mId)
  #puts menu
  h = {}
  h[:id] = params["args"]
  h[:cmd] = "search_menu"
  h[:text] = "Search"
  menu.unshift(h)
  return menu
end

def search_menu(pNm,mId,params)
  r = SendToPlayer(mId)
  menu = []
  r["payload"].each do |s|
    h = {}
    h[:cmd] = "search_service"
    h[:id] = "browse/search?#{mId.split("?")[1]}&scid=#{s["scid"]}"
    h[:text] = "Find #{s["name"]}"
    h[:args] = s
    h[:iInput] = true
    puts h
    menu << h
  end
  return menu
end

def search_service(pNm,mId,params)
  puts "#{__method__}"
  puts "MID: #{mId}"
  puts params
  r = SendToPlayer("#{mId}&search=#{params["search"]}")
  #puts r
  b = []
  
    r["payload"].each do |s|
      s["name"] = URI.decode(s["name"])
      
      #if s["sid"]
      #  id = "sid=#{s["sid"]}"
      #elsif s["mid"]
      #  id = "#{mId.split("&cid=")[0]}&mid=#{s["mid"]}"
      #else
      #  id = "#{mId.split("&cid=")[0]}&cid=#{s["cid"]}"
      #end
      
      id = "#{mId.match(/.+?\?([^\&]+)&.+/).captures[0]}&cid=#{s["cid"]}"
      
      #puts s
      img = s["image_url"] || s["image_uri"]
      if s["image_url"] == "" && j
        img = j[s["name"]] || img
      end
      if img.include?("opml.radiotime.com")
        img = ""
      end
      #puts img
      
      h = {}
      h[:id] = id
      h[:cmd] = s["type"]
      h[:text] = s["name"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})
      h[:icon] = img if img.length > 0
      h[:iContext] = true if s["playable"] == "yes"
      b << h
      
    end
    
  return b
end

def heos_server(pNm,mId,params)
  return StandardBrowse(mId)
end

def container(pNm,mId,params)
  return StandardBrowse(mId)
end

def album(pNm,mId,params)
  return StandardBrowse(mId)
end

def artist(pNm,mId,params)
  return StandardBrowse(mId)
end

def genre(pNm,mId,params)
  return StandardBrowse(mId)
end

def station(pNm,mId,params)
  SendToPlayer("browse/play_stream?#{mId}&pid=#{@@playerDB[pNm][:HeosId]}")
  return {}
end

def song(pNm,mId,params)
puts "#{__method__} Partially Implemented: #{msg}"
puts params
  SendToPlayer("browse/add_to_queue?pid=#{@@playerDB[pNm][:HeosId]}&#{mId}&aid=1")
  return {}
end

def queue(pNm,mId,params)
  #puts "Queuing"
  SendToPlayer(mId)
  return {}
end

def manage_playing(pNm,mId,params)
  #"player/get_queue?pid=1&range=0,10"
  
  r = SendToPlayer("player/get_now_playing_media?pid=#{@@playerDB[pNm][:HeosId]}")
  
  b = []
  r = SendToPlayer("player/get_queue?pid=#{@@playerDB[pNm][:HeosId]}")
  #puts r
  if r
    h = {}
    h[:id] = "save"
    h[:cmd] = "queue_save"
    h[:text] = "Save Playlist"
    h[:iInput] = true

    b << h
    r["payload"].each do |s|
      if s["sid"]
        id = "sid=#{s["sid"]}"
      elsif s["mid"]
        id = "#{mId.split("&cid=")[0]}&mid=#{s["mid"]}"
      else
        id = "#{mId.split("&cid=")[0]}&cid=#{s["cid"]}"
      end
      #puts s
      img = s["image_url"] || s["image_uri"]
      if s["image_url"] == "" && j
        img = j[s["name"]] || img
      end
      if img.include?("opml.radiotime.com")
        img = ""
      end
      #puts img
      h = {}
      h[:id] = s["qid"]
      h[:cmd] = "queue_jump"
      h[:text] = "#{s["qid"]}. #{s["song"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})}\n"\
                 "#{s["artist"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})} - "\
                 "#{s["album"].encode("ASCII", {:invalid => :replace, :undef => :replace, :replace => ''})}"
      h[:icon] = img if img.length > 0
      h[:iContext] = true
      b << h
    end
  end
  return b
end

def manage_groups(pNm,mId,params)
puts "#{__method__} Not Implemented: #{msg}"
end

#Unsolicited messaged below

def sources_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def players_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def groups_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def source_data_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def player_state_changed(msg)
  if @@playerDB[msg["name"]]
    pNm = msg["name"]
    @@playerDB[pNm][:PlayState] = msg["state"]
  end
end

def player_now_playing_changed(msg)
  if @@playerDB[msg["name"]]
    pNm = msg["name"]
    @@playerDB[pNm][:Info] = nil
  end
end

def player_now_playing_progress(msg)
  if msg["name"]
    @@playerDB[msg["name"]][:Position] = msg["cur_pos"].to_i/1000
    @@playerDB[msg["name"]][:Timestamp] = Time.new
    @@playerDB[msg["name"]][:Duration] = msg["duration"].to_i/1000
  end
end

def player_queue_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def player_volume_changed(msg)
  if msg["name"]
    @@playerDB[msg["name"]][:Volume] = msg["level"].to_i
    m = 0
    m = 1 if msg["mute"] == "on"
    @@playerDB[msg["name"]][:Mute] = m
  end
end

def player_mute_changed(msg)
  #puts __method__
  #puts msg
  if msg["name"]
    m = 0
    m = 1 if msg["state"] == "on"
    @@playerDB[msg["name"]][:Mute] = m
  end
end

def repeat_mode_changed(msg)
  if msg["name"]
    case msg["repeat"]
    when "on_all"
      r = 1
    when "on_one"
      r = 2
    else
      r = 0
    end
    @@playerDB[msg["name"]][:Repeat] = r
  end
end

def shuffle_mode_changed(msg)
  if msg["name"]
    case msg["shuffle"]
    when "on"
      s = 1
    else
      s = 0
    end
    @@playerDB[msg["name"]][:Shuffle] = s
  end
end

def group_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def group_volume_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def group_mute_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

def user_changed(msg)
puts "#{__method__} Not Implemented: #{msg}"
end

MaintainSocket()
end
