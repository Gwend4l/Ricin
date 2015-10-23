using ToxCore; // only in this file

// so we don't conflict with libtoxcore
[CCode (cprefix="ToxWrapper", lower_case_cprefix="tox_wrapper_")]
namespace Tox {
  public enum UserStatus {
    ONLINE,
    AWAY,
    BUSY,
    OFFLINE
  }

  public string profile_dir () {
    return Environment.get_user_config_dir () + "/tox/";
  }

  public class Tox : Object {
    internal ToxCore.Tox handle;
    private HashTable<uint32, Friend> friends = new HashTable<uint32, Friend> (direct_hash, direct_equal);
    private bool ipv6_enabled = true;
    private string? profile = null;
    internal Gdk.Pixbuf? avatar = null;

    public string username {
      owned get {
        uint8[] chars = new uint8[this.handle.self_get_name_size ()];
        this.handle.self_get_name (chars);
        return Util.arr2str (chars);
      }
      set {
        this.handle.self_set_name (value.data, null);
      }
    }

    public string status_message {
      owned get {
        uint8[] chars = new uint8[this.handle.self_get_status_message_size ()];
        this.handle.self_get_status_message (chars);
        return Util.arr2str (chars);
      }
      set {
        this.handle.self_set_status_message (value.data, null);
      }
    }

    public UserStatus status {
      get {
        return (UserStatus) this.handle.status;
      }
      set {
        this.handle.status = (ToxCore.UserStatus) value;
      }
    }

    public void send_avatar (string path) {
      this.avatar = new Gdk.Pixbuf.from_file (path);
      debug (@"avatar = $path");

      foreach (var friend in friends.get_values ()) {
        friend.send_avatar ();
      }
    }

    public bool connected { get; set; default = false; }

    public string id {
      owned get {
        //uint8 address[ToxCore.ADDRESS_SIZE]; // vala bug #756376
        uint8[] address = new uint8[ToxCore.ADDRESS_SIZE];
        this.handle.self_get_address (address);
        return Util.bin2hex (address);
      }
    }

    public string pubkey {
      owned get {
        uint8[] pkey = new uint8[ToxCore.PUBLIC_KEY_SIZE];
        this.handle.self_get_public_key (pkey);
        return Util.bin2hex (pkey);
      }
    }

    public signal void friend_request (string id, string message);
    public signal void friend_online (Friend friend);
    public signal void global_info (string message);

    public Tox (ToxCore.Options? opts = null, string? profile = null) throws ErrNew {
      debug ("ToxCore Version %u.%u.%u", ToxCore.Version.MAJOR, ToxCore.Version.MINOR, ToxCore.Version.PATCH);

      if (profile != null) {
        this.profile = profile;
        if (FileUtils.test (profile, FileTest.EXISTS)) { // load file
          FileUtils.get_data (profile, out opts.savedata_data);
          opts.savedata_type = ToxCore.SaveDataType.TOX_SAVE;
        } else { // create new file
          File.new_for_path (profile).create (FileCreateFlags.NONE, null);
        }
      }
      this.ipv6_enabled = opts.ipv6_enabled;

      ERR_NEW err;
      this.handle = new ToxCore.Tox (opts, out err);
      if (err != ERR_NEW.OK)
        throw convert_err_new (err);

      this.handle.callback_self_connection_status ((self, status) => {
        switch (status) {
          case ConnectionStatus.NONE:
            debug ("Connection: none");
            break;
          case ConnectionStatus.TCP:
            debug ("Connection: TCP");
            break;
          case ConnectionStatus.UDP:
            debug ("Connection: UDP");
            break;
        }
        this.connected = (status != ConnectionStatus.NONE);
      });

      this.handle.callback_friend_connection_status ((self, num, status) => {
        if (this.friends[num] == null) { // new friend
          this.friends[num] = new Friend (this, num);
          this.friend_online (this.friends[num]);
        }

        this.friends[num].connected = (status != ConnectionStatus.NONE);
      });

      this.handle.callback_friend_name ((self, num, name) => {
        var old_name = this.friends[num].name ?? (this.friends[num].pubkey.slice (0, 16) + "...");
        var new_name = Util.arr2str (name);
        this.friends[num].friend_info (old_name + " is now known as " + new_name);
        this.friends[num].name = new_name;
      });

      this.handle.callback_friend_status ((self, num, status) => {
        this.friends[num].status = (UserStatus) status;
      });

      this.handle.callback_friend_status_message ((self, num, message) => {
        this.friends[num].status_message = Util.arr2str (message);
      });

      this.handle.callback_friend_message ((self, num, type, message) => {
        if (type == MessageType.NORMAL) {
          this.friends[num].message (Util.arr2str (message));
        } else {
          this.friends[num].action (Util.arr2str (message));
        }
      });

      this.handle.callback_friend_typing ((self, num, is_typing) => {
        this.friends[num].typing = is_typing;
      });

      this.handle.callback_friend_request ((self, pubkey, message) => {
        pubkey.length = ToxCore.PUBLIC_KEY_SIZE;
        string id = Util.bin2hex (pubkey);
        string msg = Util.arr2str (message);
        debug (@"Friend request from $id: $msg");
        this.friend_request (id, msg);
      });

      // send
      this.handle.callback_file_chunk_request ((self, friend, file, position, length) => {
        if (length == 0) { // file transfer finished
          debug (@"friend $friend, file $file: done");
          this.friends[friend].files_send.remove (file);
          return;
        }
        debug (@"friend $friend, file $file: chunk request, pos=$position, len=$length");

        Bytes full_data = this.friends[friend].files_send[file];
        Bytes slice = full_data.slice ((int) position, (int) (position + length));

        ERR_FILE_SEND_CHUNK err2;
        this.handle.file_send_chunk (friend, file, position, slice.get_data (), out err2);

        if (err2 != ERR_FILE_SEND_CHUNK.OK)
          debug ("file_send_chunk: %d", err2);
      });

      // recv
      this.handle.callback_file_recv_control ((self, friend, file, control) => {
        if (control == FileControl.CANCEL) {
          debug (@"friend $friend, file $file: cancelled");
          this.friends[friend].files_recv.remove (file);
        } else if (control == FileControl.PAUSE) {
          debug (@"friend $friend, file $file: paused");
        } else if (control == FileControl.RESUME) {
          debug (@"friend $friend, file $file: resumed");
        } else {
          assert_not_reached ();
        }
      });

      // recv
      this.handle.callback_file_recv ((self, friend, file, kind, size, filename) => {
        if (kind == FileKind.AVATAR) {
          debug (@"friend $friend, file $file: receive avatar");
          this.friends[friend].files_recv[file] = new FileDownload.avatar ();
          this.handle.file_control (friend, file, FileControl.RESUME, null);
        } else {
          debug (@"friend $friend, file $file: file_recv");
          this.friends[friend].files_recv[file] = new FileDownload (Util.arr2str (filename));
          this.friends[friend].file_transfer (Util.arr2str (filename), size, file);
        }
      });

      // recv
      this.handle.callback_file_recv_chunk ((self, friend, file, position, data) => {
        var fr = this.friends[friend];
        assert (fr.files_recv.contains (file));
        if (data.length == 0) {
          debug (@"friend $friend, file $file: done");
          FileDownload dl = fr.files_recv[file];
          Bytes bytes = ByteArray.free_to_bytes (dl.data);
          if (dl.kind == FileKind.AVATAR) {
            try {
              var stream = new MemoryInputStream.from_bytes (bytes);
              var pixbuf = new Gdk.Pixbuf.from_stream_at_scale (stream, 48, 48, true);
              fr.avatar (pixbuf);
            } catch (Error e) {
              warning ("Error processing friend avatar: %s", e.message);
            }
          } else {
            fr.file_done (dl.name, bytes);
          }
          fr.files_recv.remove (file);
          return;
        }
        assert (fr.files_recv[file].data.len == position);
        fr.files_recv[file].data.append (data);
      });

      this.bootstrap.begin ();
    }

    public void run_loop () {
      this.schedule_loop_iteration ();
    }

    private void schedule_loop_iteration () {
      Timeout.add (this.handle.iteration_interval (), () => {
        this.handle.iterate ();
        this.schedule_loop_iteration ();
        return Source.REMOVE;
      });
    }

    private class Server : Object {
      public string owner { get; set; }
      public string region { get; set; }
      public string ipv4 { get; set; }
      public string ipv6 { get; set; }
      public uint64 port { get; set; }
      public string pubkey { get; set; }
    }

    private async void bootstrap () {
      var sess = new Soup.Session ();
      var msg = new Soup.Message ("GET", "https://build.tox.chat/job/nodefile_build_linux_x86_64_release/lastSuccessfulBuild/artifact/Nodefile.json");
      var stream = yield sess.send_async (msg, null);
      var json = new Json.Parser ();
      if (yield json.load_from_stream_async (stream, null)) {
        Server[] servers = {};
        var array = json.get_root ().get_object ().get_array_member ("servers");
        array.foreach_element ((arr, index, node) => {
          servers += Json.gobject_deserialize (typeof (Server), node) as Server;
        });
        while (!this.connected) {
          for (int i = 0; i < 4; ++i) { // bootstrap to 4 random nodes
            Server srv = servers[Random.int_range (0, servers.length)];

            bool success = false;
            bool try_ipv6 = this.ipv6_enabled && srv.ipv6 != null;
            if (!success && try_ipv6) {
              debug ("UDP bootstrap %s:%llu by %s", srv.ipv6, srv.port, srv.owner);
              success = this.handle.bootstrap (srv.ipv6, (uint16) srv.port, Util.hex2bin (srv.pubkey), null);
            }
            if (!success) {
              debug ("UDP bootstrap %s:%llu by %s", srv.ipv4, srv.port, srv.owner);
              success = this.handle.bootstrap (srv.ipv4, (uint16) srv.port, Util.hex2bin (srv.pubkey), null);
            }
            if (!success && try_ipv6) {
              debug ("TCP bootstrap %s:%llu by %s", srv.ipv6, srv.port, srv.owner);
              success = this.handle.add_tcp_relay (srv.ipv6, (uint16) srv.port, Util.hex2bin (srv.pubkey), null);
            }
            if (!success) {
              debug ("TCP bootstrap %s:%llu by %s", srv.ipv4, srv.port, srv.owner);
              success = this.handle.add_tcp_relay (srv.ipv4, (uint16) srv.port, Util.hex2bin (srv.pubkey), null);
            }
          }

          // wait 5 seconds without blocking main loop
          Timeout.add (5000, () => {
            bootstrap.callback ();
            return Source.REMOVE;
          });
          yield;
        }
        debug ("Done bootstrapping");
      }
    }

    public Friend? add_friend (string id, string message) throws ErrFriendAdd {
      if (id.length != ToxCore.ADDRESS_SIZE && id.index_of_char ('@') != -1) {
        error ("Invalid Tox ID");
      }

      ERR_FRIEND_ADD error;
      uint32 friend_num = this.handle.friend_add (Util.hex2bin (id), message.data, out error);

      switch (error) {
        case ERR_FRIEND_ADD.OK:
          debug (@"Friend request sent to $id: \"$message\"");
          return new Friend (this, friend_num);
        case ERR_FRIEND_ADD.NULL:
          throw new ErrFriendAdd.Null ("One of the arguments to the function was NULL when it was not expected.");
        case ERR_FRIEND_ADD.TOO_LONG:
          throw new ErrFriendAdd.TooLong ("The friend request message is too long.");
        case ERR_FRIEND_ADD.NO_MESSAGE:
          throw new ErrFriendAdd.NoMessage ("The friend request message was empty.");
        case ERR_FRIEND_ADD.OWN_KEY:
          throw new ErrFriendAdd.OwnKey ("You cannot add yourself.");
        case ERR_FRIEND_ADD.ALREADY_SENT:
          throw new ErrFriendAdd.AlreadySent ("You already added this friend.");
        case ERR_FRIEND_ADD.BAD_CHECKSUM:
          throw new ErrFriendAdd.BadChecksum ("ToxID is invalid.");
        case ERR_FRIEND_ADD.SET_NEW_NOSPAM:
          throw new ErrFriendAdd.BadNospam ("This ToxID have a new nospam.");
        case ERR_FRIEND_ADD.MALLOC:
          throw new ErrFriendAdd.Malloc ("A memory allocation failed when trying to increase the friend list size.");
        default:
          return null;
      }
    }

    public Friend? accept_friend_request (string id) {
      debug (@"accepting friend request from $id");
      ERR_FRIEND_ADD err;
      uint32 num = this.handle.friend_add_norequest (Util.hex2bin(id), out err);
      if (num != uint32.MAX && err == ERR_FRIEND_ADD.OK) {
        var friend = new Friend (this, num);
        this.friends[num] = friend;
        return friend;
      } else {
        error ("friend_add_norequest: %d", err);
      }
    }

    public void save_data () {
      if (this.profile != null) {
        debug ("Saving data to " + this.profile);
        uint8[] data = new uint8[this.handle.get_savedata_size ()];
        this.handle.get_savedata (data);
        FileUtils.set_data (this.profile, data);
      }
    }
  }

  public class Options : Object {
    public static ToxCore.Options copy (ToxCore.Options o) {
      var opts = create ();
      opts.ipv6_enabled = o.ipv6_enabled;
      opts.udp_enabled = o.udp_enabled;
      opts.proxy_type = o.proxy_type;
      opts.proxy_host = o.proxy_host;
      opts.proxy_port = o.proxy_port;
      opts.start_port = o.end_port;
      opts.tcp_port = o.tcp_port;
      opts.savedata_type = o.savedata_type;
      opts.savedata_data = o.savedata_data;
      return opts;
    }

    public static ToxCore.Options create () {
      // TODO: convert to exceptions
      return new ToxCore.Options (null);
    }
  }

  public class Friend : Object {
    private weak Tox tox;
    public uint32 num; // libtoxcore identifier
    public uint position;
    // Bytes is immutable
    internal HashTable<uint32, Bytes> files_send = new HashTable<uint32, Bytes> (direct_hash, direct_equal);
    // ByteArray is mutable
    internal HashTable<uint32, FileDownload> files_recv = new HashTable<uint32, FileDownload> (direct_hash, direct_equal);

    public signal void friend_info (string message);

    public Friend (Tox tox, uint32 num) {
      this.tox = tox;
      this.num = num;

      this.notify["connected"].connect ((o, p) => {
        if (!this.connected) {
          this.status = UserStatus.OFFLINE;
        }
      });
    }

    /* We could implement this as just a get { } that goes to libtoxcore, and
     * use GLib.Object.notify_property () in the callbacks, but the name is not
     * set until we leave the callback so we'll just keep our own copy.
     */
    public string name { get; set; }

    public string pubkey {
      owned get {
        uint8[] chars = new uint8[ToxCore.PUBLIC_KEY_SIZE];
        tox.handle.friend_get_public_key (num, chars, null);
        return Util.bin2hex (chars);
      }
    }

    public UserStatus status { get; set; }
    public string status_message { get; set; }
    public bool connected { get; set; }
    public bool typing { get; set; }

    public signal void message (string message);
    public signal void action (string message);
    public signal void avatar (Gdk.Pixbuf pixbuf);
    public signal void file_transfer (string filename, uint64 file_size, uint32 id);
    public signal void file_done (string filename, Bytes data);

    public void reply_file_transfer (bool accept, uint32 id) {
      tox.handle.file_control (this.num, id, accept ? FileControl.RESUME : FileControl.CANCEL, null);
    }

    public void send_message (string message) {
      debug (@"sending \"$message\" to friend $num");
      ERR_FRIEND_SEND_MESSAGE err;
      tox.handle.friend_send_message (this.num, MessageType.NORMAL, message.data, out err);
    }

    public void send_action (string action_message) {
      debug (@"sending action \"$action_message\" to friend $num");
      ERR_FRIEND_SEND_MESSAGE err;
      tox.handle.friend_send_message (this.num, MessageType.ACTION, action_message.data, out err);
    }

    public void send_avatar () {
      if (tox.avatar != null) {
        uint8[] pixels;
        tox.avatar.save_to_buffer (out pixels, "png");

        uint8[] avatar_id = new uint8[ToxCore.HASH_LENGTH];
        ToxCore.Tox.hash (avatar_id, pixels);

        debug (@"sending avatar to friend $num");
        ERR_FILE_SEND err;
        uint32 transfer = this.tox.handle.file_send (this.num, FileKind.AVATAR, pixels.length, avatar_id, null, out err);
        if (err != ERR_FILE_SEND.OK) {
          debug ("tox_file_send: %d", err);
        }

        this.files_send[transfer] = new Bytes (pixels);
      }
    }

    public void send_file (string path) {
      debug (@"Sending $path to friend $num");
      var file = File.new_for_path (path);
      var info = file.query_info ("standard::size", FileQueryInfoFlags.NONE);
      var id = this.tox.handle.file_send (this.num, FileKind.DATA, info.get_size (), null, file.get_basename ().data, null);
      uint8[] data;
      FileUtils.get_data (path, out data);
      this.files_send[id] = new Bytes.take (data);
    }

    public bool delete () throws ErrFriendDelete {
      ERR_FRIEND_DELETE err;
      var retval = this.tox.handle.friend_delete (this.num, out err);

      switch (err) {
        case ERR_FRIEND_DELETE.FRIEND_NOT_FOUND:
          throw new ErrFriendDelete.NotFound ("There was no friend with the given friend number. No friends were deleted.");
      }

      return retval;
    }
  }

  private class FileDownload : Object {
    public FileKind kind;
    public string? name = null;
    //public bool paused = false;
    public ByteArray data = new ByteArray ();

    public FileDownload (string name) {
      this.name = name;
      this.kind = FileKind.DATA;
    }

    public FileDownload.avatar () {
      this.kind = FileKind.AVATAR;
    }
  }
}
