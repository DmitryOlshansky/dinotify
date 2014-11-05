/**
    A tiny library to work with Linux's kernel inotify subsystem.

*/
module dinotify;

private:

///
unittest
{
    import std.process, std.stdio : writeln;
    auto monitor = iNotify();
    system("mkdir tmp");
    // literals are zero-terminated
    monitor.add("tmp".ptr, IN_CREATE | IN_DELETE);
    ubyte[] data = [1, 2, 3, 4];
    system("touch tmp/killme");
    auto events = monitor.read();
    assert(events[0].mask == IN_CREATE);
    assert(events[0].name == "killme");

    system("rm -rf tmp/killme");
    events = monitor.read();
    assert(events[0].mask == IN_DELETE);

    // Note: watched directory doesn't track events in sub-directories
    system("mkdir tmp/some-dir");
    system("touch tmp/some-dir/victim");
    events = monitor.read();
    assert(events.length == 1);
    assert(events[0].mask == (IN_ISDIR | IN_CREATE | IN_MOVE));
    assert(events[0].name == "some-dir");
    system("rm -rf tmp");
}

import core.sys.posix.unistd;
import core.sys.linux.sys.inotify;
import std.exception;

// core.sys.linux is lacking, so just list proper prototypes on our own
extern(C){
    size_t strnlen(const(char)* s, size_t maxlen);
    enum NAME_MAX = 255;
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

/// D-ified inotify event, holds slice to temporary buffer with z-string.
public struct Event{
    Watch watch;
    uint mask, cookie;
    const(char)[] name;
}

public struct INotify{
    private int fd = -1; // inotify fd
    private ubyte[] buffer;
    private Event[] events;
    
    private this(int fd){
        enforce(fd >= 0, "failed to init inotify");
        this.fd = fd;
        buffer = new ubyte[20*maxEvent];
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
    Event[] read(){
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
            events ~= Event(Watch(eptr.wd), eptr.mask, eptr.cookie, name(*eptr));
        }
        return events;
    }
    
    ~this(){
        if(fd >= 0)
            close(fd);
    }
}

/// Create new INotify struct
public auto iNotify(){ return INotify(inotify_init()); }

/++
    Event as returned by INotifyTree.
    In constrast to Event, it has full path and no watch descriptor.
+/
public struct TreeEvent{
    uint mask;
    string path;
}

/++
    Track events in the whole directory tree, automatically adding watches to
    any new sub-directories and stopping watches in the deleted ones.
+/
public struct INotifyTree{
    private INotify inotify;
    private uint mask;
    private Watch[string] watches;
    private string[Watch] paths;
    TreeEvent[] events;

    private void addWatch(string dirPath){
        auto wd = watches[dirPath] = inotify.add(dirPath, mask | IN_CREATE | IN_DELETE_SELF);
        paths[wd] = dirPath;
    }

    private void rmWatch(Watch w){
        auto p = paths[w];
        paths.remove(w);
        watches.remove(p);
    }

    private this(string path, uint mask){
        import std.file;
        inotify = iNotify();
        this.mask = mask;
        addWatch(path); //root
        foreach(d; dirEntries(path, SpanMode.breadth)){
            if(d.isDir) addWatch(d.name);
        }
    }

    ///
    TreeEvent[] read(){
        import std.stdio;
        events.length = 0;
        events.assumeSafeAppend();
        // filter events for IN_DELETE_SELF to remove watches
        // and monitor IN_CREATE with IN_ISDIR to create new watches
        do{
            auto evs = inotify.read();
            foreach(e; evs){
                //writeln(e);
                assert(e.watch in paths); //invariant
                string path = paths[e.watch];
                path ~= "/" ~ e.name; //FIXME: always allocates
                if(e.mask & IN_ISDIR){
                    if(e.mask & IN_CREATE)
                        addWatch(path);
                    else if(e.mask & IN_DELETE_SELF){
                        rmWatch(e.watch);
                    }
                }
                //writeln(path);
                // user may not be interested in IN_CREATE or IN_DELETE_SELF
                // but we have to track them
                if(mask & e.mask)
                    events ~= TreeEvent(e.mask, path);
            }
        }while(events.length == 0); // some events get filtered... may be even all of them
        return events;
    }
}

///
public auto iNotifyTree(string path, uint mask){
    return INotifyTree(path, mask);
}

///
unittest
{
    import std.process;
    system("rm -rf tmp");
    system("mkdir -p tmp/dir1/dir11");
    system("mkdir -p tmp/dir1/dir12");
    auto ntree = iNotifyTree("tmp/dir1", IN_CREATE | IN_DELETE);
    system("touch tmp/dir1/dir11/a.tmp");
    system("touch tmp/dir1/dir12/b.tmp");
    system("rm -rf tmp/dir1/dir12");
    auto evs = ntree.read();
    assert(evs.length == 4);
    // a & b files created
    assert(evs[0].mask == IN_CREATE && evs[0].path == "tmp/dir1/dir11/a.tmp");
    assert(evs[1].mask == IN_CREATE && evs[1].path == "tmp/dir1/dir12/b.tmp");
    // b deleted as part of sub-tree
    assert(evs[2].mask == IN_DELETE && evs[2].path == "tmp/dir1/dir12/b.tmp");
    assert(evs[3].mask == (IN_DELETE | IN_ISDIR) && evs[3].path == "tmp/dir1/dir12");
}