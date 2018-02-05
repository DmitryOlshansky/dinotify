# -*- mode: python; -*-

project(
    'dinotify',
    'd',
    version: '0.2.2',
    default_options: ['buildtype=release'],
)

sources =  [
    'source/dinotify.d',
]

shared_library(
    meson.project_name(),
    sources,
    version: meson.project_version(),
    soversion: '0',
    install: true,
)

static_library(
    meson.project_name(),
    sources,
    install: true,
)

install_data('source/dinotify.d', install_dir: get_option('prefix') + '/include/d')

# The pkgconfig system produces C/C++ library flags which are of
# little use with ldc2, so must do things the hard way. :-(

pc_file_data = configuration_data()
pc_file_data.set('NAME', meson.project_name())
pc_file_data.set('VERSION', meson.project_version())
pc_file_data.set('DESCRIPTION', 'A tiny D library to work with Linux\'s kernel inotify file events subsystem.')
pc_file_data.set('LIBS', '-L-L${libdir} -L-l' + meson.project_name())
pc_file_data.set('CFLAGS', '-I${includedir}/d')
pc_file_data.set('PREFIX', get_option('prefix'))
pc_file = configure_file(configuration: pc_file_data, input: meson.project_name() + '.pc.in', output: meson.project_name() + '.pc')

install_data(pc_file, install_dir: 'share/pkgconfig')

testExecutable = executable(
    'dinotify-test',
    sources,
    d_args: ['-unittest'],
    link_args: ['--main'],
)

test('all tests', testExecutable)
