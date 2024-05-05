dinotify
========

[![Build Status](https://github.com/DmitryOlshansky/dinotify/actions/workflows/d.yml/badge.svg)

A tiny D library to work with Linux's kernel inotify file events subsystem.

Compared to other solutions it doesn't try to be cross-platform and
pretend to abstract away inotify-specific quirks.

For cross-platform library, see [FSWatch](https://github.com/WebFreak001/FSWatch).

## [Documentation](https://dmitryolshansky.github.io/dinotify/dinotify.html)

Docs are pretty bare ATM, since I've never used DDox before. Looks ugly, I'll try BootDDoc theme next.

## Synopsis

Low-level full control version with `iNotify` function to create a inotify watch descriptor. Please read Linux man on inotify, as dinotify uses the same enumerations for masks.

```d
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

```

High-level wrapper that does recursive registration with `iNotifyTree`. 

```d
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
```
