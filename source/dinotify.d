/**
    A tiny library to work with Linux's kernel inotify subsystem.

*/
module dinotify;

private:

///
unittest
{
    import std.file, std.stdio : writeln;
    auto monitor = iNotify();
    monitor.add(tempDir, IN_CREATE | IN_DELETE);
    ubyte[] data = [1, 2, 3, 4];
    write(tempDir ~ "/killme", data);
    auto events = monitor.read();
    assert(events[0].mask & IN_CREATE);
    assert(events[0].name == "killme");
    remove(tempDir ~ "/killme");
    events = monitor.read();
    assert(events[0].mask & IN_DELETE);
    // Note: doesn't track nested directories
    mkdir(tempDir ~ "/some-dir");
    write(tempDir ~ "/some-dir/victim", data);
    events = monitor.read();
    assert(events.length == 1);
    assert(events[0].mask & IN_CREATE);
    assert(events[0].name == "some-dir");
    remove(tempDir ~ "/some-dir/victim");
    rmdir(tempDir ~ "/some-dir/");

}

import core.sys.posix.unistd;
import std.exception;

// core.sys.linux is lacking, so just list proper prototypes on our own
extern(C){

    /// Event data-structure as returned by the OS,
    /// has trailing name field (a C-style thing)
    public struct inotify_event {
       int  wd;     /** Watch descriptor */
       uint mask;   /** Mask describing event */
       uint cookie; /** Unique cookie associating related
                       events (for rename(2)) */
       uint len;    /** Size of name field */
       //char[0] name; /* Optional null-terminated name */
    }

    int inotify_init();
    int inotify_init1(int flags);
    int inotify_add_watch(int fd, const char *pathname, uint mask);
    int inotify_rm_watch(int fd, int wd);

    size_t strnlen(const(char)* s, size_t maxlen);
    enum NAME_MAX = 255;
    
    /// Flags to use in INotify.add
    public enum
        IN_ACCESS = 0x00000001,      /** File was accessed */
        IN_MODIFY = 0x00000002,      /** File was modified */
        IN_ATTRIB = 0x00000004,      /** Metadata changed */
        IN_CLOSE_WRITE = 0x00000008,      /** Writtable file was closed */
        IN_CLOSE_NOWRITE = 0x00000010,      /** Unwrittable file closed */
        IN_OPEN = 0x00000020,      /** File was opened */
        IN_MOVED_FROM = 0x00000040,      /** File was moved from X */
        IN_MOVED_TO = 0x00000080,      /** File was moved to Y */
        IN_CREATE = 0x00000100,      /** Subfile was created */
        IN_DELETE = 0x00000200,      /** Subfile was deleted */
        IN_DELETE_SELF = 0x00000400,      /** Self was deleted */
        IN_MOVE_SELF = 0x00000800;      /** Self was moved */
}

auto size(ref inotify_event e) { return e.sizeof + e.len; }

// Get name out of event structure
const(char)[] name(ref inotify_event e)
{
    auto ptr = cast(const(char)*)(&e+1); 
    auto len = strnlen(ptr, e.len);
    return ptr[0..len];
}

auto maxEvent(){ return inotify_event.sizeof + NAME_MAX + 1; }

/// Type-safe watch descriptor to help discern it from normal file descriptors
public struct Watch{
    private int wd;   
}

/// D-ified intofiy event, holds slice to temporary buffer with z-string.
public struct Event{
    uint mask, cookie;
    const(char)[] name;
}

public struct INotify{
    private int fd; // inotify fd
    private ubyte[] buffer;
    private Event[] events;
    
    private this(int fd){
        enforce(fd >= 0, "failed to init inotify");
        this.fd = fd;
        buffer = new ubyte[maxEvent];
    }

    @disable this(this);

    /// Add path to watch set of this INotify instance
    Watch add(const (char)* path, uint mask){
        auto w = Watch(inotify_add_watch(fd, path, mask));
        enforce(w.wd >= 0, "failed to add inotify watch");
        return w;
    }

    /// ditto
    Watch add(const (char)[] path, uint mask){
        auto zpath = path ~ '\0';
        return add(zpath.ptr, mask);
    }

    /// Remove watch descriptor from this this INotify instance
    void remove(Watch w){
        enforce(inotify_rm_watch(fd, w.wd) == 0,
            "failed to remove inotify watch");
    }

    /**
        Issue a blocking read to get a bunch of events,
        there is at least one event in the returned slice.

        Note that returned slice is mutable.
        This indicates that it is invalidated on 
        the next call to read, just like byLine in std.stdio.
    */
    Event[] read()
    {
        long len = .read(fd, buffer.ptr, buffer.length);
        enforce(len > 0, "failed to read inotify event");
        ubyte* head = buffer.ptr;
        events.length = 0;
        events.assumeSafeAppend();        
        while(len > 0){
            auto eptr = cast(inotify_event*)head;
            auto sz = size(*eptr);
            head += sz;
            len -= sz;
            events ~= Event(eptr.mask, eptr.cookie, name(*eptr));
        }
        return events;
    }
    
    ~this(){
        if(fd >= 0)
            close(fd);
    }
}

///
public auto iNotify(){ return INotify(inotify_init()); }