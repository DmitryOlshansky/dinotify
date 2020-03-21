# -*- mode: python; -*-

project(
    'dinotify',
    'd',
    version: '0.4.0',
    meson_version: '>=0.41',
    default_options: ['buildtype=release'],
)

sources =  [
    'source/dinotify.d',
]

install_headers(sources, subdir: 'd/')

sharedlib = library(
    meson.project_name(),
    sources,
    version: meson.project_version(),
    pic: true,
    install: true,
)

pkgconfig = import('pkgconfig')
pkgconfig.generate(
    name: meson.project_name(),
    libraries: sharedlib,
    subdirs: 'd/',
    version: meson.project_version(),
    description: 'A D library to work with Linux\'s kernel inotify file events subsystem.'
)

testExecutable = executable(
    'dinotify-test',
    sources,
    d_args: ['-unittest'],
    link_args: ['--main'],
)

test('all tests', testExecutable)

dinotfy_dep = declare_dependency(
    link_with: sharedlib,
    include_directories: [include_directories('source/')],
)
