/*
 * libjingle
 * Copyright 2004--2005, Google Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *  2. Redistributions in binary form must reproduce the above copyright notice,
 *     this list of conditions and the following disclaimer in the documentation
 *     and/or other materials provided with the distribution.
 *  3. The name of the author may not be used to endorse or promote products
 *     derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "RootViewController.h"

#include "talk/examples/iphone/gtalkclient.h"

#include <string>

#include "talk/xmpp/constants.h"
#include "talk/base/helpers.h"
#include "talk/base/thread.h"
#include "talk/base/network.h"
#include "talk/base/socketaddress.h"
#include "talk/base/stringutils.h"
#include "talk/p2p/base/sessionmanager.h"
#include "talk/p2p/client/basicportallocator.h"
#include "talk/p2p/client/sessionmanagertask.h"
#include "talk/session/phone/devicemanager.h"
#include "talk/session/phone/mediaengine.h"
#include "talk/session/phone/mediasessionclient.h"
#include "talk/examples/iphone/presencepushtask.h"
#include "talk/examples/iphone/presenceouttask.h"
#include "talk/examples/iphone/mucinviterecvtask.h"
#include "talk/examples/iphone/mucinvitesendtask.h"
#include "talk/examples/iphone/friendinvitesendtask.h"
#include "talk/examples/iphone/muc.h"
#include "talk/examples/iphone/voicemailjidrequester.h"
#ifdef USE_TALK_SOUND
#include "talk/sound/platformsoundsystemfactory.h"
#endif

#include "talk/base/logging.h"

class NullRenderer : public cricket::VideoRenderer {
 public:
  explicit NullRenderer(const char* s) : s_(s) {}
 private:
  bool SetSize(int width, int height, int reserved) {
    LOG(LS_INFO) << "Video size for " << s_ << ": " << width << "x" << height;
    return true;
  }
  bool RenderFrame(const cricket::VideoFrame *frame) {
    return true;
  }
  const char* s_;
};

namespace {

const char* DescribeStatus(buzz::Status::Show show, const std::string& desc) {
  switch (show) {
  case buzz::Status::SHOW_XA:      return desc.c_str();
  case buzz::Status::SHOW_ONLINE:  return "online";
  case buzz::Status::SHOW_AWAY:    return "away";
  case buzz::Status::SHOW_DND:     return "do not disturb";
  case buzz::Status::SHOW_CHAT:    return "ready to chat";
  default:                         return "offline";
  }
}

}  // namespace

const char* CALL_COMMANDS =
"Available commands:\n"
"\n"
"  hangup  Ends the call.\n"
"  mute    Stops sending voice.\n"
"  unmute  Re-starts sending voice.\n"
"  dtmf    Sends a DTMF tone.\n"
"  quit    Quits the application.\n"
"";

const char* RECEIVE_COMMANDS =
"Available commands:\n"
"\n"
"  accept  Accepts the incoming call and switches to it.\n"
"  reject  Rejects the incoming call and stays with the current call.\n"
"  quit    Quits the application.\n"
"";

const char* CONSOLE_COMMANDS =
"Available commands:\n"
"\n"
"  roster              Prints the online friends from your roster.\n"
"  friend user         Request to add a user to your roster.\n"
"  call [jid]          Initiates a call to the user[/room] with the\n"
"                      given JID.\n"
"  vcall [jid]         Initiates a video call to the user[/room] with\n"
"                      the given JID.\n"
"  voicemail [jid]     Leave a voicemail for the user with the given JID.\n"
"  join [room]         Joins a multi-user-chat.\n"
"  invite user [room]  Invites a friend to a multi-user-chat.\n"
"  leave [room]        Leaves a multi-user-chat.\n"
"  getdevs             Prints the available media devices.\n"
"  quit                Quits the application.\n"
"";

void gtalkClient::ParseLine(const std::string& line) {
  std::vector<std::string> words;
  int start = -1;
  int state = 0;
  for (int index = 0; index <= static_cast<int>(line.size()); ++index) {
    if (state == 0) {
      if (!isspace(line[index])) {
        start = index;
        state = 1;
      }
    } else {
      ASSERT(state == 1);
      ASSERT(start >= 0);
      if (isspace(line[index])) {
        std::string word(line, start, index - start);
        words.push_back(word);
        start = -1;
        state = 0;
      }
    }
  }

  // Global commands
  if ((words.size() == 1) && (words[0] == "quit")) {
    Quit();
  } else if (call_ && incoming_call_) {
    if ((words.size() == 1) && (words[0] == "accept")) {
      Accept();
    } else if ((words.size() == 1) && (words[0] == "reject")) {
      Reject();
    } else {
      printf("RECEIVE_COMMANDS");
    }
  } else if (call_) {
    if ((words.size() == 1) && (words[0] == "hangup")) {
      // TODO: do more shutdown here, move to Terminate()
      call_->Terminate();
      call_ = NULL;
      session_ = NULL;
    } else if ((words.size() == 1) && (words[0] == "mute")) {
      call_->Mute(true);
    } else if ((words.size() == 1) && (words[0] == "unmute")) {
      call_->Mute(false);
    } else if ((words.size() == 2) && (words[0] == "dtmf")) {
      int ev = std::string("0123456789*#").find(words[1][0]);
      call_->PressDTMF(ev);
    } else {
      printf("CALL_COMMANDS");
    }
  } else {
    if ((words.size() == 1) && (words[0] == "roster")) {
      PrintRoster();
    } else if ((words.size() == 2) && (words[0] == "friend")) {
      InviteFriend(words[1]);
    } else if ((words.size() >= 1) && (words[0] == "call")) {
      MakeCallTo((words.size() >= 2) ? words[1] : "", false);
    } else if ((words.size() >= 1) && (words[0] == "vcall")) {
      MakeCallTo((words.size() >= 2) ? words[1] : "", true);
    } else if ((words.size() >= 1) && (words[0] == "join")) {
      JoinMuc((words.size() >= 2) ? words[1] : "");
    } else if ((words.size() >= 2) && (words[0] == "invite")) {
      InviteToMuc(words[1], (words.size() >= 3) ? words[2] : "");
    } else if ((words.size() >= 1) && (words[0] == "leave")) {
      LeaveMuc((words.size() >= 2) ? words[1] : "");
    } else if ((words.size() == 1) && (words[0] == "getdevs")) {
      GetDevices();
    } else if ((words.size() == 2) && (words[0] == "setvol")) {
      SetVolume(words[1]);
    } else if ((words.size() >= 1) && (words[0] == "voicemail")) {
      CallVoicemail((words.size() >= 2) ? words[1] : "");
    } else {
      printf("CONSOLE_COMMANDS");
    }
  }
}

gtalkClient::gtalkClient(buzz::XmppClient* xmpp_client, void * controller)
    : xmpp_client_(xmpp_client), controller_(controller), media_engine_(NULL), media_client_(NULL),
      call_(NULL), incoming_call_(false),
      auto_accept_(false), pmuc_domain_("groupchat.google.com"),
      local_renderer_(NULL), remote_renderer_(NULL),
      roster_(new RosterMap), portallocator_flags_(0)
#ifdef USE_TALK_SOUND
      , sound_system_factory_(NULL)
#endif
    {
  xmpp_client_->SignalStateChange.connect(this, &gtalkClient::OnStateChange);
}

gtalkClient::~gtalkClient() {
  delete media_client_;
  delete roster_;
}

const std::string gtalkClient::strerror(buzz::XmppEngine::Error err) {
  switch (err) {
    case  buzz::XmppEngine::ERROR_NONE:
      return "";
    case  buzz::XmppEngine::ERROR_XML:
      return "Malformed XML or encoding error";
    case  buzz::XmppEngine::ERROR_STREAM:
      return "XMPP stream error";
    case  buzz::XmppEngine::ERROR_VERSION:
      return "XMPP version error";
    case  buzz::XmppEngine::ERROR_UNAUTHORIZED:
      return "User is not authorized (Check your username and password)";
    case  buzz::XmppEngine::ERROR_TLS:
      return "TLS could not be negotiated";
    case  buzz::XmppEngine::ERROR_AUTH:
      return "Authentication could not be negotiated";
    case  buzz::XmppEngine::ERROR_BIND:
      return "Resource or session binding could not be negotiated";
    case  buzz::XmppEngine::ERROR_CONNECTION_CLOSED:
      return "Connection closed by output handler.";
    case  buzz::XmppEngine::ERROR_DOCUMENT_CLOSED:
      return "Closed by </stream:stream>";
    case  buzz::XmppEngine::ERROR_SOCKET:
      return "Socket error";
    default:
      return "Unknown error";
  }
}

void gtalkClient::OnCallDestroy(cricket::Call* call) {
  if (call == call_) {
    if (remote_renderer_) {
      delete remote_renderer_;
      remote_renderer_ = NULL;
    }
    if (local_renderer_) {
      delete local_renderer_;
      local_renderer_ = NULL;
    }
    printf("call destroyed");
    call_ = NULL;
    session_ = NULL;
  }
}

void gtalkClient::OnStateChange(buzz::XmppEngine::State state) {		  
	RootViewController * tvc = (RootViewController*)controller_;
  switch (state) {
  case buzz::XmppEngine::STATE_START:
    printf("connecting...");
		  [tvc.roster_ removeAllObjects];
		  [tvc.roster_ addObject:@"connecting..."];
		  [tvc reloadTableViewData];
    break;

  case buzz::XmppEngine::STATE_OPENING:
    printf("logging in...");
		  [tvc.roster_ removeAllObjects];
		  [tvc.roster_ addObject:@"logging in..."];
		  [tvc reloadTableViewData];
    break;

  case buzz::XmppEngine::STATE_OPEN:
    printf("logged in...");
		  [tvc.roster_ removeAllObjects];
		  [tvc.roster_ addObject:@"logged in..."];
		  [tvc reloadTableViewData];
    InitPhone();
    InitPresence();
		  // prepare to add roster
		  [tvc.roster_ removeAllObjects];
    break;

  case buzz::XmppEngine::STATE_CLOSED:
    buzz::XmppEngine::Error error = xmpp_client_->GetError(NULL);
    printf("logged out...%s", strerror(error).c_str());
		  [tvc.roster_ removeAllObjects];
		  [tvc.roster_ addObject:@"logged out..."];
		  [tvc reloadTableViewData];
	Quit();
  }
}

void gtalkClient::InitPhone() {
  std::string client_unique = xmpp_client_->jid().Str();
  talk_base::InitRandom(client_unique.c_str(), client_unique.size());

  worker_thread_ = new talk_base::Thread();
  // The worker thread must be started here since initialization of
  // the ChannelManager will generate messages that need to be
  // dispatched by it.
  worker_thread_->Start();

  network_manager_ = new talk_base::NetworkManager();

  // TODO: Decide if the relay address should be specified here.
  talk_base::SocketAddress stun_addr("stun.l.google.com", 19302);
  port_allocator_ =
      new cricket::BasicPortAllocator(network_manager_, stun_addr,
          talk_base::SocketAddress(), talk_base::SocketAddress(),
          talk_base::SocketAddress());

  if (portallocator_flags_ != 0) {
    port_allocator_->set_flags(portallocator_flags_);
  }
  session_manager_ = new cricket::SessionManager(
      port_allocator_, worker_thread_);
  session_manager_->SignalRequestSignaling.connect(
      this, &gtalkClient::OnRequestSignaling);
  session_manager_->OnSignalingReady();

  session_manager_task_ =
      new cricket::SessionManagerTask(xmpp_client_, session_manager_);
  session_manager_task_->EnableOutgoingMessages();
  session_manager_task_->Start();

#ifdef USE_TALK_SOUND
  if (!sound_system_factory_) {
    sound_system_factory_ = new cricket::PlatformSoundSystemFactory();
  }
#endif

  if (!media_engine_) {
    media_engine_ = cricket::MediaEngine::Create(
#ifdef USE_TALK_SOUND
        sound_system_factory_
#endif
        );
  }

  media_client_ = new cricket::MediaSessionClient(
      xmpp_client_->jid(),
      session_manager_,
      media_engine_,
      new cricket::DeviceManager(
#ifdef USE_TALK_SOUND
          sound_system_factory_
#endif
          ));
  media_client_->SignalCallCreate.connect(this, &gtalkClient::OnCallCreate);
  media_client_->SignalDevicesChange.connect(this,
                                             &gtalkClient::OnDevicesChange);
}

void gtalkClient::OnRequestSignaling() {
  session_manager_->OnSignalingReady();
}

void gtalkClient::OnCallCreate(cricket::Call* call) {
  call->SignalSessionState.connect(this, &gtalkClient::OnSessionState);
  if (call->video()) {
    local_renderer_ = new NullRenderer("local");
    remote_renderer_ = new NullRenderer("remote");
  }
}

void gtalkClient::OnSessionState(cricket::Call* call,
                                cricket::BaseSession* session,
                                cricket::BaseSession::State state) {
  if (state == cricket::Session::STATE_RECEIVEDINITIATE) {
    buzz::Jid jid(session->remote_name());
    printf("Incoming call from '%s'", jid.Str().c_str());
    call_ = call;
    session_ = session;
    incoming_call_ = true;
    if (auto_accept_) {
      Accept();
    }
  } else if (state == cricket::Session::STATE_SENTINITIATE) {
    printf("calling...");
  } else if (state == cricket::Session::STATE_RECEIVEDACCEPT) {
    printf("call answered");
  } else if (state == cricket::Session::STATE_RECEIVEDREJECT) {
    printf("call not answered");
  } else if (state == cricket::Session::STATE_INPROGRESS) {
    printf("call in progress");
  } else if (state == cricket::Session::STATE_RECEIVEDTERMINATE) {
    printf("other side hung up");
  }
}

void gtalkClient::InitPresence() {
  presence_push_ = new buzz::PresencePushTask(xmpp_client_, this);
  presence_push_->SignalStatusUpdate.connect(
    this, &gtalkClient::OnStatusUpdate);
  presence_push_->SignalMucJoined.connect(this, &gtalkClient::OnMucJoined);
  presence_push_->SignalMucLeft.connect(this, &gtalkClient::OnMucLeft);
  presence_push_->SignalMucStatusUpdate.connect(
    this, &gtalkClient::OnMucStatusUpdate);
  presence_push_->Start();

  presence_out_ = new buzz::PresenceOutTask(xmpp_client_);
  RefreshStatus();
  presence_out_->Start();

  muc_invite_recv_ = new buzz::MucInviteRecvTask(xmpp_client_);
  muc_invite_recv_->SignalInviteReceived.connect(this,
      &gtalkClient::OnMucInviteReceived);
  muc_invite_recv_->Start();

  muc_invite_send_ = new buzz::MucInviteSendTask(xmpp_client_);
  muc_invite_send_->Start();

  friend_invite_send_ = new buzz::FriendInviteSendTask(xmpp_client_);
  friend_invite_send_->Start();
}

void gtalkClient::RefreshStatus() {
  int media_caps = media_client_->GetCapabilities();
  my_status_.set_jid(xmpp_client_->jid());
  my_status_.set_available(true);
  my_status_.set_show(buzz::Status::SHOW_ONLINE);
  my_status_.set_priority(0);
  my_status_.set_know_capabilities(true);
  my_status_.set_pmuc_capability(true);
  my_status_.set_phone_capability(
      (media_caps & cricket::MediaEngine::AUDIO_RECV) != 0);
  my_status_.set_video_capability(
      (media_caps & cricket::MediaEngine::VIDEO_RECV) != 0);
  my_status_.set_camera_capability(
      (media_caps & cricket::MediaEngine::VIDEO_SEND) != 0);
  my_status_.set_is_google_client(true);
  my_status_.set_version("1.0.0.67");
  presence_out_->Send(my_status_);
}

void gtalkClient::OnStatusUpdate(const buzz::Status& status) {
  RosterItem item;
  item.jid = status.jid();
  item.show = status.show();
  item.status = status.status();

  std::string key = item.jid.Str();
	std::string roster_name = item.jid.node() + "@" + item.jid.domain();
	RootViewController * tvc = (RootViewController*)controller_;

  if (status.available() && status.phone_capability()) {
     printf("Adding to roster: %s", key.c_str());
    (*roster_)[key] = item;
	  [tvc.roster_ addObject:[NSString stringWithFormat:@"%s", roster_name.c_str()]];
	  [tvc reloadTableViewData];
  } else {
    printf("Removing from roster: %s", key.c_str());
    RosterMap::iterator iter = roster_->find(key);
    if (iter != roster_->end())
      roster_->erase(iter);
  }
}

void gtalkClient::PrintRoster() {
  printf("Roster contains %d callable", (int)roster_->size());
  RosterMap::iterator iter = roster_->begin();
  while (iter != roster_->end()) {
    printf("%s - %s",
                     iter->second.jid.BareJid().Str().c_str(),
                     DescribeStatus(iter->second.show, iter->second.status));
    iter++;
  }
}

void gtalkClient::InviteFriend(const std::string& name) {
  buzz::Jid jid(name);
  if (!jid.IsValid() || jid.node() == "") {
    printf("Invalid JID. JIDs should be in the form user@domain\n");
    return;
  }
  // Note: for some reason the Buzz backend does not forward our presence
  // subscription requests to the end user when that user is another call
  // client as opposed to a Smurf user. Thus, in that scenario, you must
  // run the friend command as the other user too to create the linkage
  // (and you won't be notified to do so).
  friend_invite_send_->Send(jid);
  printf("Requesting to befriend %s.\n", name.c_str());
}

void gtalkClient::MakeCallTo(const std::string& name, bool video) {
  bool found = false;
  bool is_muc = false;
  buzz::Jid callto_jid(name);
  buzz::Jid found_jid;
  if (name.length() == 0 && mucs_.size() > 0) {
    // if no name, and in a MUC, establish audio with the MUC
    found_jid = mucs_.begin()->first;
    found = true;
    is_muc = true;
  } else if (name[0] == '+') {
    // if the first character is a +, assume it's a phone number
    found_jid = callto_jid;
    found = true;
  } else if (callto_jid.resource() == "voicemail") {
    // if the resource is /voicemail, allow that
    found_jid = callto_jid;
    found = true;
  } else {
    // otherwise, it's a friend
    for (RosterMap::iterator iter = roster_->begin();
         iter != roster_->end(); ++iter) {
      if (iter->second.jid.BareEquals(callto_jid)) {
        found = true;
        found_jid = iter->second.jid;
        break;
      }
    }

    if (!found) {
      if (mucs_.count(callto_jid) == 1 &&
          mucs_[callto_jid]->state() == buzz::Muc::MUC_JOINED) {
        found = true;
        found_jid = callto_jid;
        is_muc = true;
      }
    }
  }

  if (found) {
    printf("Found %s '%s'", is_muc ? "room" : "online friend",
        found_jid.Str().c_str());
    PlaceCall(found_jid, is_muc, video);
  } else {
    printf("Could not find online friend '%s'", name.c_str());
  }
}

void gtalkClient::PlaceCall(const buzz::Jid& jid, bool is_muc, bool video) {
  media_client_->SignalCallDestroy.connect(
      this, &gtalkClient::OnCallDestroy);
  if (!call_) {
    call_ = media_client_->CreateCall(video, is_muc);
    session_ = call_->InitiateSession(jid);
    if (is_muc) {
      // If people in this room are already in a call, must add all their
      // streams.
      buzz::Muc::MemberMap& members = mucs_[jid]->members();
      for (buzz::Muc::MemberMap::iterator elem = members.begin();
           elem != members.end();
           ++elem) {
        AddStream(elem->second.audio_src_id(), elem->second.video_src_id());
      }
    }
  }
  media_client_->SetFocus(call_);
  if (call_->video()) {
    call_->SetLocalRenderer(local_renderer_);
    // TODO: Call this once for every different remote SSRC
    // once we get to testing multiway video.
    call_->SetVideoRenderer(session_, 0, remote_renderer_);
  }
}

void gtalkClient::CallVoicemail(const std::string& name) {
  buzz::Jid jid(name);
  if (!jid.IsValid() || jid.node() == "") {
    printf("Invalid JID. JIDs should be in the form user@domain\n");
    return;
  }
  buzz::VoicemailJidRequester *request =
    new buzz::VoicemailJidRequester(xmpp_client_, jid, my_status_.jid());
  request->SignalGotVoicemailJid.connect(this,
                                         &gtalkClient::OnFoundVoicemailJid);
  request->SignalVoicemailJidError.connect(this,
                                           &gtalkClient::OnVoicemailJidError);
  request->Start();
}

void gtalkClient::OnFoundVoicemailJid(const buzz::Jid& to,
                                     const buzz::Jid& voicemail) {
  printf("Calling %s's voicemail.\n", to.Str().c_str());
  PlaceCall(voicemail, false, false);
}

void gtalkClient::OnVoicemailJidError(const buzz::Jid& to) {
  printf("Unable to voicemail %s.\n", to.Str().c_str());
}

void gtalkClient::AddStream(uint32 audio_src_id, uint32 video_src_id) {
  if (audio_src_id || video_src_id) {
    printf("Adding stream (%u, %u)\n", audio_src_id, video_src_id);
    call_->AddStream(session_, audio_src_id, video_src_id);
  }
}

void gtalkClient::RemoveStream(uint32 audio_src_id, uint32 video_src_id) {
  if (audio_src_id || video_src_id) {
    printf("Removing stream (%u, %u)\n", audio_src_id, video_src_id);
    call_->RemoveStream(session_, audio_src_id, video_src_id);
  }
}

void gtalkClient::Accept() {
  ASSERT(call_ && incoming_call_);
  ASSERT(call_->sessions().size() == 1);
  call_->AcceptSession(call_->sessions()[0]);
  media_client_->SetFocus(call_);
  if (call_->video()) {
    call_->SetLocalRenderer(local_renderer_);
    // The client never does an accept for multiway, so this must be 1:1,
    // so there's no SSRC.
    call_->SetVideoRenderer(session_, 0, remote_renderer_);
  }
  incoming_call_ = false;
}

void gtalkClient::Reject() {
  ASSERT(call_ && incoming_call_);
  call_->RejectSession(call_->sessions()[0]);
  incoming_call_ = false;
}

void gtalkClient::Quit() {
  talk_base::Thread::Current()->Quit();
}

void gtalkClient::JoinMuc(const std::string& room) {
  buzz::Jid room_jid;
  if (room.length() > 0) {
    room_jid = buzz::Jid(room);
  } else {
    // generate a GUID of the form XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX,
    // for an eventual JID of private-chat-<GUID>@groupchat.google.com
    char guid[37], guid_room[256];
    for (size_t i = 0; i < ARRAY_SIZE(guid) - 1;) {
      if (i == 8 || i == 13 || i == 18 || i == 23) {
        guid[i++] = '-';
      } else {
        sprintf(guid + i, "%04x", rand());
        i += 4;
      }
    }

    talk_base::sprintfn(guid_room, ARRAY_SIZE(guid_room),
                        "private-chat-%s@%s", guid, pmuc_domain_.c_str());
    room_jid = buzz::Jid(guid_room);
  }

  if (!room_jid.IsValid()) {
    printf("Unable to make valid muc endpoint for %s", room.c_str());
    return;
  }

  MucMap::iterator elem = mucs_.find(room_jid);
  if (elem != mucs_.end()) {
    printf("This MUC already exists.");
    return;
  }

  buzz::Muc* muc = new buzz::Muc(room_jid, xmpp_client_->jid().node());
  mucs_[room_jid] = muc;
  presence_out_->SendDirected(muc->local_jid(), my_status_);
}

void gtalkClient::OnMucInviteReceived(const buzz::Jid& inviter,
    const buzz::Jid& room,
    const std::vector<buzz::AvailableMediaEntry>& avail) {

  printf("Invited to join %s by %s.\n", room.Str().c_str(),
      inviter.Str().c_str());
  printf("Available media:\n");
  if (avail.size() > 0) {
    for (std::vector<buzz::AvailableMediaEntry>::const_iterator i =
            avail.begin();
        i != avail.end();
        ++i) {
      printf("  %s, %s\n",
          buzz::AvailableMediaEntry::TypeAsString(i->type),
          buzz::AvailableMediaEntry::StatusAsString(i->status));
    }
  } else {
    printf("  None\n");
  }
  // We automatically join the room.
  JoinMuc(room.Str());
}

void gtalkClient::OnMucJoined(const buzz::Jid& endpoint) {
  MucMap::iterator elem = mucs_.find(endpoint);
  ASSERT(elem != mucs_.end() &&
         elem->second->state() == buzz::Muc::MUC_JOINING);

  buzz::Muc* muc = elem->second;
  muc->set_state(buzz::Muc::MUC_JOINED);
  printf("Joined \"%s\"", muc->jid().Str().c_str());
}

void gtalkClient::OnMucStatusUpdate(const buzz::Jid& jid,
    const buzz::MucStatus& status) {

  // Look up this muc.
  MucMap::iterator elem = mucs_.find(jid);
  ASSERT(elem != mucs_.end() &&
         elem->second->state() == buzz::Muc::MUC_JOINED);

  buzz::Muc* muc = elem->second;

  if (status.jid().IsBare() || status.jid() == muc->local_jid()) {
    // We are only interested in status about other users.
    return;
  }

  if (!status.available()) {
    // User is leaving the room.
    buzz::Muc::MemberMap::iterator elem =
      muc->members().find(status.jid().resource());

    ASSERT(elem != muc->members().end());

    // If user had src-ids, they have the left the room without explicitly
    // hanging-up; must tear down the stream if in a call to this room.
    if (call_ && session_->remote_name() == muc->jid().Str()) {
      RemoveStream(elem->second.audio_src_id(), elem->second.video_src_id());
    }

    // Remove them from the room.
    muc->members().erase(elem);
  } else {
    // Either user has joined or something changed about them.
    // Note: The [] operator here will create a new entry if it does not
    // exist, which is what we want.
    buzz::MucStatus& member_status(
        muc->members()[status.jid().resource()]);
    if (call_ && session_->remote_name() == muc->jid().Str()) {
      // We are in a call to this muc. Must potentially update our streams.
      // The following code will correctly update our streams regardless of
      // whether the SSRCs have been removed, added, or changed and regardless
      // of whether that has been done to both or just one. This relies on the
      // fact that AddStream/RemoveStream do nothing for SSRC arguments that are
      // zero.
      uint32 remove_audio_src_id = 0;
      uint32 remove_video_src_id = 0;
      uint32 add_audio_src_id = 0;
      uint32 add_video_src_id = 0;
      if (member_status.audio_src_id() != status.audio_src_id()) {
        remove_audio_src_id = member_status.audio_src_id();
        add_audio_src_id = status.audio_src_id();
      }
      if (member_status.video_src_id() != status.video_src_id()) {
        remove_video_src_id = member_status.video_src_id();
        add_video_src_id = status.video_src_id();
      }
      // Remove the old SSRCs, if any.
      RemoveStream(remove_audio_src_id, remove_video_src_id);
      // Add the new SSRCs, if any.
      AddStream(add_audio_src_id, add_video_src_id);
    }
    // Update the status. This will use the compiler-generated copy
    // constructor, which is perfectly adequate for this class.
    member_status = status;
  }
}

void gtalkClient::LeaveMuc(const std::string& room) {
  buzz::Jid room_jid;
  if (room.length() > 0) {
    room_jid = buzz::Jid(room);
  } else if (mucs_.size() > 0) {
    // leave the first MUC if no JID specified
    room_jid = mucs_.begin()->first;
  }

  if (!room_jid.IsValid()) {
    printf("Invalid MUC JID.");
    return;
  }

  MucMap::iterator elem = mucs_.find(room_jid);
  if (elem == mucs_.end()) {
    printf("No such MUC.");
    return;
  }

  buzz::Muc* muc = elem->second;
  muc->set_state(buzz::Muc::MUC_LEAVING);

  buzz::Status status;
  status.set_jid(my_status_.jid());
  status.set_available(false);
  status.set_priority(0);
  presence_out_->SendDirected(muc->local_jid(), status);
}

void gtalkClient::OnMucLeft(const buzz::Jid& endpoint, int error) {
  // We could be kicked from a room from any state.  We would hope this
  // happens While in the MUC_LEAVING state
  MucMap::iterator elem = mucs_.find(endpoint);
  if (elem == mucs_.end())
    return;

  buzz::Muc* muc = elem->second;
  if (muc->state() == buzz::Muc::MUC_JOINING) {
    printf("Failed to join \"%s\", code=%d",
                     muc->jid().Str().c_str(), error);
  } else if (muc->state() == buzz::Muc::MUC_JOINED) {
    printf("Kicked from \"%s\"",
                     muc->jid().Str().c_str());
  }

  delete muc;
  mucs_.erase(elem);
}

void gtalkClient::InviteToMuc(const std::string& user, const std::string& room) {
  // First find the room.
  const buzz::Muc* found_muc;
  if (room.length() == 0) {
    if (mucs_.size() == 0) {
      printf("Not in a room yet; can't invite.\n");
      return;
    }
    // Invite to the first muc
    found_muc = mucs_.begin()->second;
  } else {
    MucMap::iterator elem = mucs_.find(buzz::Jid(room));
    if (elem == mucs_.end()) {
      printf("Not in room %s.\n", room.c_str());
      return;
    }
    found_muc = elem->second;
  }
  // Now find the user. We invite all of their resources.
  bool found_user = false;
  buzz::Jid user_jid(user);
  for (RosterMap::iterator iter = roster_->begin();
       iter != roster_->end(); ++iter) {
    if (iter->second.jid.BareEquals(user_jid)) {
      muc_invite_send_->Send(iter->second.jid, *found_muc);
      found_user = true;
    }
  }
  if (!found_user) {
    printf("No such friend as %s.\n", user.c_str());
    return;
  }
}

void gtalkClient::GetDevices() {
  std::vector<std::string> names;
  media_client_->GetAudioInputDevices(&names);
  printf("Audio input devices:\n");
  PrintDevices(names);
  media_client_->GetAudioOutputDevices(&names);
  printf("Audio output devices:\n");
  PrintDevices(names);
  media_client_->GetVideoCaptureDevices(&names);
  printf("Video capture devices:\n");
  PrintDevices(names);
}

void gtalkClient::PrintDevices(const std::vector<std::string>& names) {
  for (size_t i = 0; i < names.size(); ++i) {
    printf("%d: %s\n", static_cast<int>(i), names[i].c_str());
  }
}

void gtalkClient::OnDevicesChange() {
  printf("Devices changed.\n");
  RefreshStatus();
}

void gtalkClient::SetVolume(const std::string& level) {
  media_client_->SetOutputVolume(strtol(level.c_str(), NULL, 10));
}
