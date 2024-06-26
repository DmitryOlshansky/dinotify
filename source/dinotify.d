/**
    A tiny library to work with Linux's kernel inotify subsystem.

*/
module dinotify;

import core.time;
import core.sys.posix.unistd;
import core.sys.posix.poll;
import core.sys.posix.sys.stat;
public import core.sys.linux.sys.inotify;
import std.exception, std.string;

private:

// core.sys.linux is lacking, so just list proper prototypes on our own
extern (C)
{
    size_t strnlen(const(char)* s, size_t maxlen);
    enum NAME_MAX = 255;
}
    
auto size(ref inotify_event e)
{
    return e.sizeof + e.len;
}

// Get name out of event structure
const(char)[] name(ref inotify_event e)
{
    auto ptr = cast(const(char)*)(&e+1); 
    auto len = strnlen(ptr, e.len);
    return ptr[0..len];
}

auto maxEvent()
{
    return inotify_event.sizeof + NAME_MAX + 1;
}

/// Type-safe watch descriptor to help discern it from normal file descriptors
public struct Watch
{
    private int wd;   
}

/// D-ified inotify event, holds slice to temporary buffer with z-string.
public struct Event
{
    Watch watch;
    uint mask, cookie;
    const(char)[] name;
}

public struct INotify
{
    private int fd = -1; // inotify fd
    private ubyte[] buffer;
    private Event[] events;
    
    private this(int fd)
    {
        enforce(fd >= 0, "failed to init inotify");
        this.fd = fd;
        buffer = new ubyte[20*maxEvent];
    }

    @disable this(this);

    public @property int descriptor(){ return fd; }

    /// Add path to watch set of this INotify instance
    Watch add(const(char)* path, uint mask)
    {
        auto w = Watch(inotify_add_watch(fd, path, mask));
        enforce(w.wd >= 0, "failed to add inotify watch");
        return w;
    }

    /// ditto
    Watch add(const(char)[] path, uint mask)
    {
        auto zpath = path ~ '\0';
        return add(zpath.ptr, mask);
    }

    /// Remove watch descriptor from this this INotify instance
    void remove(Watch w)
    {
        enforce(inotify_rm_watch(fd, w.wd) == 0, "failed to remove inotify watch");
    }

    /**
        Issue a blocking read to get a bunch of events,
        there is at least one event in the returned slice.
        
        If no event occurs within specified timeout returns empty array.
        Occuracy of timeout is in miliseconds.

        Note that returned slice is mutable.
        This indicates that it is invalidated on 
        the next call to read, just like byLine in std.stdio.
    */
    Event[] read(Duration timeout)
    {
        return readImpl(cast(int)timeout.total!"msecs");
    }

    Event[] read()
    {
        return readImpl(-1);
    }

    private Event[] readImpl(int timeout)
    {
        pollfd pfd;
        pfd.fd = fd;
        pfd.events = POLLIN;
        if (poll(&pfd, 1, timeout) <= 0) return null;
        long len = .read(fd, buffer.ptr, buffer.length);
        enforce(len > 0, "failed to read inotify event");
        ubyte* head = buffer.ptr;
        events.length = 0;
        events.assumeSafeAppend();
        while (len > 0)
        {
            auto eptr = cast(inotify_event*)head;
            auto sz = size(*eptr);
            head += sz;
            len -= sz;
            events ~= Event(Watch(eptr.wd), eptr.mask, eptr.cookie, name(*eptr));
        }
        return events;
    }
    
    ~this()
    {
        if(fd >= 0)
            close(fd);
    }
}

/// Create new INotify struct
public auto iNotify()
{
    return INotify(inotify_init1(IN_NONBLOCK));
}

///
unittest
{
    import std.process, std.stdio : writeln, writefln;

    auto monitor = iNotify();
    executeShell("rm -rf tmp");
    executeShell("mkdir tmp");
    // literals are zero-terminated
    monitor.add("tmp".ptr, IN_CREATE | IN_DELETE);
    ubyte[] data = [1, 2, 3, 4];
    executeShell("touch tmp/killme");
    auto events = monitor.read();
    assert(events[0].mask == IN_CREATE);
    assert(events[0].name == "killme");

    executeShell("rm -rf tmp/killme");
    events = monitor.read();
    assert(events[0].mask == IN_DELETE);

    // Note: watched directory doesn't track events in sub-directories
    executeShell("mkdir tmp/some-dir");
    executeShell("touch tmp/some-dir/victim");
    events = monitor.read();
    assert(events.length == 1);
    assert(events[0].mask == (IN_ISDIR | IN_CREATE));
    assert(events[0].name == "some-dir");
}

/++
    Event as returned by INotifyTree.
    In constrast to Event, it has full path and no watch descriptor.
+/
public struct TreeEvent
{
    uint mask;
    string path;
}

/++
    Track events in the whole directory tree, automatically adding watches to
    any new sub-directories and stopping watches in the deleted ones.
+/
public struct INotifyTree
{
    private INotify inotify;
    private uint mask;
    private Watch[string] watches;
    private string[Watch] paths;
    private bool[ulong] inodes;
    private ulong[string] path2inodes;
    TreeEvent[] events;

    private bool addWatch(string dirPath)
    {
        stat_t st;
        if (stat(dirPath.toStringz, &st) < 0) {
            return false;
        }
        if (st.st_ino in inodes) {
            return false;
        }
        auto wd = watches[dirPath] = inotify.add(dirPath, mask | IN_CREATE | IN_DELETE_SELF);
        paths[wd] = dirPath;
        inodes[st.st_ino] = true;
        path2inodes[dirPath] = st.st_ino;
        return true;
    }

    private void rmWatch(Watch w)
    {
        auto p = paths[w];
        paths.remove(w);
        watches.remove(p);
        auto inode = path2inodes[p];
        inodes.remove(inode);
        path2inodes.remove(p);
    }

    private this(string[] roots, uint mask)
    {
        import std.file;

        void processDir(string root) {
            if (!addWatch(root)) return;
            foreach (d; dirEntries(root, SpanMode.shallow))
            {
                if (d.isDir)
                    processDir(d.name);
            }
        }

        inotify = iNotify();
        this.mask = mask;
        foreach (root; roots) {
            processDir(root);
        }
    }

    public @property int descriptor(){ return inotify.descriptor; }

    private TreeEvent[] readImpl(int timeout)
    {
        events.length = 0;
        events.assumeSafeAppend();
        // filter events for IN_DELETE_SELF to remove watches
        // and monitor IN_CREATE with IN_ISDIR to create new watches
        do
        {
            auto evs = inotify.readImpl(timeout);
            if (evs.length == 0) return null;
            foreach (e; evs)
            {
                assert(e.watch in paths); //invariant
                string path = paths[e.watch];
                path ~= "/" ~ e.name; //FIXME: always allocates
                if (e.mask & IN_ISDIR)
                {
                    if (e.mask & IN_CREATE)
                        addWatch(path);
                    else if (e.mask & IN_DELETE_SELF)
                    {
                        rmWatch(e.watch);
                    }
                }
                // user may not be interested in IN_CREATE or IN_DELETE_SELF
                // but we have to track them
                if (mask & e.mask)
                    events ~= TreeEvent(e.mask, path);
            }
        }
        while (events.length == 0); // some events get filtered... may be even all of them
        return events;
    }

    /// Read events from `iNotifyTree` with timeout.
    /// In contrast with `iNotify`, it lists full path to file (from the root of directory)
    TreeEvent[] read(Duration timeout)
    {
        return readImpl(cast(int)timeout.total!"msecs");
    }   

    /// Same as `read` but blocks the thread until some inotify event comes on watches.
    TreeEvent[] read()
    {
        return readImpl(-1);
    }   
}

/// Create a INotifyTree to recusivly establish watches in `path`,
/// using `mask` to choose which events to watch on.
public auto iNotifyTree(string path, uint mask)
{
    return INotifyTree([path], mask);
}
public auto iNotifyTree(string[] roots, uint mask)
{
    return INotifyTree(roots, mask);
}

///
unittest
{
    import std.process;
    import core.thread;

    executeShell("rm -rf tmp");
    executeShell("mkdir -p tmp/dir1/dir11");
    executeShell("mkdir -p tmp/dir1/dir12");
    auto ntree = iNotifyTree("tmp/dir1", IN_CREATE | IN_DELETE);
    executeShell("touch tmp/dir1/dir11/a.tmp");
    executeShell("touch tmp/dir1/dir12/b.tmp");
    executeShell("rm -rf tmp/dir1/dir12");
    auto evs = ntree.read();
    assert(evs.length == 4);
    // a & b files created
    assert(evs[0].mask == IN_CREATE && evs[0].path == "tmp/dir1/dir11/a.tmp");
    assert(evs[1].mask == IN_CREATE && evs[1].path == "tmp/dir1/dir12/b.tmp");
    // b deleted as part of sub-tree
    assert(evs[2].mask == IN_DELETE && evs[2].path == "tmp/dir1/dir12/b.tmp");
    assert(evs[3].mask == (IN_DELETE | IN_ISDIR) && evs[3].path == "tmp/dir1/dir12");
    evs = ntree.read(10.msecs);
    assert(evs.length == 0);
    auto t = new Thread((){
        Thread.sleep(1000.msecs);
        executeShell("touch tmp/dir1/dir11/c.tmp");
    }).start();
    evs = ntree.read(10.msecs);
    t.join();
    assert(evs.length == 0);
    evs = ntree.read(10.msecs);
    assert(evs.length == 1);
}

