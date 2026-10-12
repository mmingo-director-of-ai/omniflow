# Loads OmniFlow's Now Playing bridge into this Apple-signed interpreter.
use strict;
use DynaLoader;
my $library = DynaLoader::dl_load_file($ARGV[0], 0) or exit 2;
my $symbol = DynaLoader::dl_find_symbol($library, "omniflow_nowplaying_run") or exit 2;
DynaLoader::dl_install_xsub("main::run", $symbol);
run();
