/*
Copyright 2016 HaCk3D, substanceof

https://github.com/HaCk3Dq
https://github.com/substanceof

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import std.process, std.stdio, std.string,
       std.array, std.algorithm, std.conv,
       std.math, std.file, std.ascii,
       std.socket, std.json;
import core.thread;
import app, utils;
import vkapi: VkMan;

struct Track {
  string artist, title, duration, playtime, id;
  int durationSeconds;
}

__gshared MusicPlayer mplayer;
__gshared VkMan api;

class MusicPlayer {
  __gshared {
    mpv player;
    Track currentTrack;
    bool
      playtimeUpdated,
      trackOverStateCatched = true, //for reject empty strings before playback starts
      repeatMode,
      shuffleMode;
    Track[] playlist;
    string
      stockProgress = "=".replicate(50),
      realProgress  = "|" ~ "=".replicate(49);
    int position, trackNum, offset;
  }

  const updateWait = dur!"msecs"(1000);

  this() {
    player = new mpv(
      sec => setPlaytime(sec, false)
    );
  }

  void exitPlayer() {
    player.exit();
  }

  bool musicState() {
    return player.getMusicState();
  }

  void pause() {
    player.pause();
  }

  bool playerExit() {
    return player.isPlayerExit();
  }

  bool isInit() {
    return player.isPlayerInit();
  }

  void play(int position) {
    trackOverStateCatched = true;
    trackNum = position;
    auto track = api.getBufferedMusic(1, position)[0];
    currentTrack = Track(track.artist, track.title, track.duration_str, "", track.id.to!string, track.duration_sec);
    loadFile(track.url);
  }

  void loadFile(string url) {
    realProgress = "|" ~ "=".replicate(49);
    auto p = prepareTrackUrl(url);
    player.loadfile(p);
  }

  void startPlayer(VkMan vkapi) {
    currentTrack.playtime = "0:00";
    api = vkapi;
    player.start();
  }

  string durToStr(real duration) {
    auto intDuration = lround(duration);
    auto min = intDuration / 60;
    auto sec = intDuration - (60*min);
    return min.to!string ~ ":" ~ sec.to!int.tzr;
  }

  void setPlaytime(real sec, bool end) {
    if (!end) {
        real
          trackd = currentTrack.durationSeconds.to!real,
          step =  trackd / 50;
        int newPos = floor(sec / step).to!int;
        currentTrack.playtime = durToStr(sec);
        if (position != newPos) {
          position = newPos;

          if(newPos >= 50) newPos = 49;
          else if (newPos < 0) newPos = 0;

          auto newProgress = stockProgress.dup;
          newProgress[newPos] = '|';
          realProgress = newProgress.to!string;
        }
        playtimeUpdated = true;
        trackOverStateCatched = false;
    }
    else {
      if(!trackOverStateCatched) trackOver();
    }
  }

  string prepareTrackUrl(string trackurl) {
    if(trackurl.startsWith("https://")) return trackurl.replace("https://", "http://");
    else return trackurl;
  }

  void trackOver() {
    if (musicState) {
      dbm("catched trackOver");
      trackOverStateCatched = true;
      if (!repeatMode) trackNum++;
      auto track = api.getBufferedMusic(1, trackNum)[0];
      loadFile(track.url);
      currentTrack = Track(track.artist, track.title, track.duration_str, "", track.id.to!string, track.duration_sec);
    }
    playtimeUpdated = true;
  }

  ListElement[] getMplayerUI(int cols) {
    ListElement[] playerUI;
    auto fcols = cols-16;
    auto artistrepl = fcols/2-currentTrack.artist.utfLength/2;
    auto titlerepl = fcols/2-currentTrack.title.utfLength/2;

    if (fcols < 1) fcols = cols;
    if (artistrepl < 1) artistrepl = 1;
    if (titlerepl < 1) titlerepl = 1;

    playerUI ~= ListElement(" ".replicate(artistrepl)~currentTrack.artist);
    playerUI ~= ListElement(" ".replicate(titlerepl)~currentTrack.title);
    playerUI ~= ListElement(center(currentTrack.playtime ~ " / " ~ currentTrack.duration, fcols, ' '));
    playerUI ~= ListElement(center("[" ~ realProgress ~ "]", fcols, ' '));
    return playerUI;
  }

  bool sameTrack(int position) {
    auto track = api.getBufferedMusic(1, position)[0];
    return currentTrack.id == track.id.to!string;
  }
}

class mpv: Thread {

  enum ipcCmd {
    playbackTime,
    pause,
    exit,
    load
  }

  struct ipcCmdParams {
    ipcCmd command;
    string argument;
  }

  const
    socketPath = "/tmp/vkmpv",
    playerExec = "mpv --idle --no-audio-display --input-ipc-server=" ~ socketPath ~ " > /dev/null 2> /dev/null";

  const
    int
      posPropertyId = 1,
      idlePropertyId = 2;

  alias posCallback = void delegate(real sec);

  posCallback posChanged;

  string commandTemplate = "{ \"command\": [] }";
  string[] output;
  Socket comm;
  Address commAddr;
  bool
    isInit,
    playerExit,
    musicState;


  this(posCallback pos) {
    posChanged = pos;
    super(&runPlayer);
  }


  private void req(string cmd) {
    if(!isInit) {
      dbm("mpv - req: noinit");
      return;
    }

    dbm("mpv - req cmd: " ~ cmd);

    auto s_answ = comm.send(cmd ~ "\n");
    if(s_answ == Socket.ERROR) {
      dbm("mpv - req: s_answ error");
      return;
    }

  }

  private void mpvsend(ipcCmdParams c) {

    JSONValue cm = parseJSON(commandTemplate);

    switch(c.command) {
      case ipcCmd.playbackTime:
        cm.object["command"].array ~= JSONValue("get_property");
        cm.object["command"].array ~= JSONValue("playback-time");
        break;
      case ipcCmd.pause:
        cm.object["command"].array ~= JSONValue("set_property");
        cm.object["command"].array ~= JSONValue("pause");
        cm.object["command"].array ~= JSONValue(musicState);
        break;
      case ipcCmd.exit:
        cm.object["command"].array ~= JSONValue("quit");
        break;
      case ipcCmd.load:
        cm.object["command"].array ~= JSONValue("loadfile");
        cm.object["command"].array ~= JSONValue(c.argument);
        break;
      default: assert(0);
    }

    dbm("mpv - cmd: " ~ c.command.to!string);

    req(cm.toString());
  }

  private void mpvhandle(string rc) {
    try {
      auto m = parseJSON(rc);
      if(m.type != JSON_TYPE.OBJECT) return;
      if("error" in m) {
        if(m["error"].str != "success") {
          dbm("mpv - error: " ~ rc);
        }
      }
      else if("event" in m) {
        auto e = m["event"].str;

        switch(e) {
          case "property-change":
            auto eid = m["id"].integer.to!int;
            if(eid == posPropertyId) posChanged(m["data"].floating.to!real);
          break;



          default: break;
        }

      }
    }
    catch(JSONException e) {
      dbm("mpv - json exception: " ~ e.msg);
    }
  }

  private JSONValue observePropertyCmd(int id, string prop) {
    auto c = parseJSON(commandTemplate);
    c["command"].array ~= JSONValue("observe_property");
    c["command"].array ~= JSONValue(id);
    c["command"].array ~= JSONValue(prop);
    return c;
  }

  private void setup() {
    req(observePropertyCmd(posPropertyId, "playback-time").toString());
    req(observePropertyCmd(idlePropertyId, "idle").toString());
  }

  void runPlayer() {
    dbm("mpv - starting");
    auto pipe = pipeProcess("sh", Redirect.stdin);
    pipe.stdin.writeln(playerExec);
    pipe.stdin.flush;
    Thread.sleep(dur!"msecs"(500)); //wait for init
    dbm("mpv - running");

    assert(exists(socketPath));
    commAddr = new UnixAddress(socketPath);
    comm = new Socket(AddressFamily.UNIX, SocketType.STREAM);
    comm.connect(commAddr);
    dbm("mpv - socket connected");

    isInit = true;
    long r_answ = -1;
    setup();

    while( r_answ != 0 ){
      char[1024] recv;
      string recv_str;
      r_answ = comm.receive(recv);
      if(r_answ != 0) {
        foreach(r; recv) {
          if(r == '\n' || r == '\x00') break;
          recv_str ~= r;
        }
        output ~= recv_str;
        dbm("mpv - recv: " ~ recv_str);
        mpvhandle(recv_str);
        Thread.sleep( dur!"msecs"(100) );
      }
    }

    dbm("PLAYER EXIT");
    playerExit = true;
  }

  void pause() {
    auto c = ipcCmdParams(ipcCmd.pause);
    mpvsend(c);
    musicState = !musicState;
  }

  bool getMusicState() {
    return musicState;
  }

  bool isPlayerExit() {
    return playerExit;
  }

  bool isPlayerInit() {
    return isInit;
  }

  void exit() {
    auto c = ipcCmdParams(ipcCmd.exit);
    mpvsend(c);
  }

  void loadfile(string p) {
    auto c = ipcCmdParams(ipcCmd.load, p);
    mpvsend(c);
    musicState = true;
  }

}
