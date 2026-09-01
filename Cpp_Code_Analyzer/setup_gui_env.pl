#!/usr/bin/env perl
#
# Name:        setup_gui_env.pl
# Description: Provisions the Python environment for the PySide6 GUI that
#              lives in gui/ and consumes cpp_inspector.pl. Creates a
#              virtualenv, installs gui/requirements.txt into it, and
#              writes run_gui.sh / run_gui.bat launcher scripts at the
#              repo root.
# Usage:       perl setup_gui_env.pl [--gui=<path>] [--python=<binary>]
#                                     [--force] [--yes]
# Requirements: a python3 with the 'venv' module (python3-venv on Debian/
#               Ubuntu), internet access for pip on first run.
#

use strict;
use warnings;
use feature 'say';

use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long qw(GetOptions);

use constant {
    DEFAULT_GUI_SUBDIR => 'gui',
    DEFAULT_VENV_NAME  => '.venv',
    REQ_FILENAME       => 'requirements.txt',
};

main();
exit 0;

# ----------------------------------------------------------------------
sub main {
    refuse_to_run_as_root();

    my $opts = parse_arguments(@ARGV);

    my $repo_root = dirname( abs_path($0) );
    my $gui_dir   = resolve_gui_dir( $repo_root, $opts->{gui} );

    say "[*] Repo root: $repo_root";
    say "[*] GUI subproject: $gui_dir\n";

    my $python = find_python( $opts->{python} );
    say "[1/6] Using Python interpreter: $python";
    check_venv_module($python);

    my $req_path = File::Spec->catfile( $gui_dir, REQ_FILENAME );
    die "Error: '$req_path' not found. Is --gui pointing at the right directory?\n"
      unless -f $req_path;
    say "[2/6] Found requirements file: $req_path";

    my $venv_dir = File::Spec->catdir( $gui_dir, DEFAULT_VENV_NAME );
    say "[3/6] Preparing virtualenv at: $venv_dir";
    maybe_create_venv( $python, $venv_dir, $opts->{force}, $opts->{yes} );

    my ( $venv_python, $venv_pip ) = venv_binaries($venv_dir);

    say "[4/6] Upgrading pip inside the virtualenv...";
    run_or_die( $venv_python, '-m', 'pip', 'install', '--upgrade', 'pip' );

    say "[5/6] Installing GUI dependencies from $req_path...";
    run_or_die( $venv_pip, 'install', '-r', $req_path );

    say "[6/6] Writing launcher scripts...";
    write_launchers( $repo_root, $gui_dir, $venv_dir );

    check_analysis_tools();

    print_summary( $repo_root, $gui_dir, $venv_dir );
    return;
}

# ----------------------------------------------------------------------
# Setup / validation helpers
# ----------------------------------------------------------------------

sub refuse_to_run_as_root {
    return unless $^O ne 'MSWin32' && $> == 0;
    die "Error: Running this script as 'root' is not allowed for security reasons.\n"
      . "Please run it as a normal user.\n";
}

sub parse_arguments {
    local @ARGV = @_;

    my %opts = (
        gui    => DEFAULT_GUI_SUBDIR,
        python => undef,
        force  => 0,
        yes    => 0,
    );
    GetOptions(
        'gui=s'    => \$opts{gui},
        'python=s' => \$opts{python},
        'force'    => \$opts{force},
        'yes|y'    => \$opts{yes},
        'help|h'   => sub { print usage(); exit 0; },
    ) or die usage();

    return \%opts;
}

sub usage {
    return <<"HELP";
Usage:
  perl $0 [options]

Options:
  --gui=<path>     Path to the GUI subproject (default: @{[ DEFAULT_GUI_SUBDIR ]}, relative to repo root)
  --python=<bin>   Python interpreter to use to create the virtualenv (default: auto-detect python3/python)
  --force          Recreate the virtualenv even if one already exists
  --yes, -y        Skip confirmation prompts (useful for CI/automation)
  --help, -h       Display this help message and exit

What this script does:
  1. Locates a usable Python 3 interpreter (with the 'venv' module).
  2. Confirms gui/requirements.txt exists.
  3. Creates a virtualenv at gui/.venv (skipped if it already exists, unless --force).
  4. Upgrades pip inside the virtualenv.
  5. Installs gui/requirements.txt (PySide6) into the virtualenv.
  6. Writes run_gui.sh (POSIX) and run_gui.bat (Windows) at the repo root.

Examples:
  perl $0
  perl $0 --force --yes
  perl $0 --python=python3.11
HELP
}

sub resolve_gui_dir {
    my ( $repo_root, $raw ) = @_;
    my $path =
      File::Spec->file_name_is_absolute($raw)
      ? $raw
      : File::Spec->catdir( $repo_root, $raw );
    die "Error: GUI directory '$path' does not exist.\n"
      . "Expected the PySide6 subproject (app.py, src/, requirements.txt) there.\n"
      unless -d $path;
    return abs_path($path);
}

sub find_python {
    my ($requested) = @_;
    my @candidates = defined $requested ? ($requested) : qw(python3 python);

    for my $candidate (@candidates) {
        my $found = find_tool_in_path($candidate);
        return $found if $found;
    }
    die "Error: no usable Python interpreter found on PATH (tried: "
      . join( ', ', @candidates )
      . "). Install Python 3 first, or pass --python=/path/to/python3.\n";
}

sub find_tool_in_path {
    my ($tool) = @_;
    return abs_path($tool) if File::Spec->file_name_is_absolute($tool) && -x $tool;
    for my $dir ( split /:/, $ENV{PATH} // '' ) {
        my $candidate = File::Spec->catfile( $dir, $tool );
        return $candidate if -x $candidate && !-d $candidate;
    }
    return undef;
}

sub check_venv_module {
    my ($python) = @_;
    system( $python, '-c', 'import venv' ) == 0
      or die "Error: '$python' cannot import the 'venv' module.\n"
      . "On Debian/Ubuntu, install it with: sudo apt-get install python3-venv\n";
    return;
}

sub maybe_create_venv {
    my ( $python, $venv_dir, $force, $auto_yes ) = @_;

    if ( -d $venv_dir && !$force ) {
        say "      Virtualenv already exists, reusing it. (use --force to recreate)";
        return;
    }

    if ( -d $venv_dir && $force ) {
        confirm_or_die(
            "[?] --force was given: delete and recreate '$venv_dir'? [y/N] ",
            $auto_yes
        );
        remove_tree_portable($venv_dir);
    }

    run_or_die( $python, '-m', 'venv', $venv_dir );
    return;
}

sub remove_tree_portable {
    my ($dir) = @_;
    require File::Path;
    File::Path::remove_tree($dir);
    return;
}

sub confirm_or_die {
    my ( $prompt, $auto_yes ) = @_;
    return if $auto_yes;

    print $prompt;
    my $answer = <STDIN>;
    $answer = defined $answer ? lc($answer) : 'n';
    chomp $answer;

    die "Aborted.\n" unless $answer =~ /^y(es)?$/;
    return;
}

sub venv_binaries {
    my ($venv_dir) = @_;
    if ( $^O eq 'MSWin32' ) {
        return (
            File::Spec->catfile( $venv_dir, 'Scripts', 'python.exe' ),
            File::Spec->catfile( $venv_dir, 'Scripts', 'pip.exe' ),
        );
    }
    return (
        File::Spec->catfile( $venv_dir, 'bin', 'python' ),
        File::Spec->catfile( $venv_dir, 'bin', 'pip' ),
    );
}

sub run_or_die {
    my (@cmd) = @_;
    say "      \$ " . join( ' ', @cmd );
    system(@cmd) == 0
      or die "Error: command failed (exit "
      . ( $? >> 8 ) . "): "
      . join( ' ', @cmd ) . "\n";
    return;
}

sub write_launchers {
    my ( $repo_root, $gui_dir, $venv_dir ) = @_;

    my ($venv_python) = venv_binaries($venv_dir);

    # POSIX launcher
    my $sh_path = File::Spec->catfile( $repo_root, 'run_gui.sh' );
    open my $sh_fh, '>', $sh_path or die "Cannot write $sh_path: $!\n";
    print {$sh_fh} <<"SH";
#!/usr/bin/env bash
# Auto-generated by setup_gui_env.pl — launches the Cpp Inspector GUI.
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "$venv_dir/bin/python" "\$SCRIPT_DIR/gui/app.py"
SH
    close $sh_fh;
    chmod 0755, $sh_path;
    say "      Wrote $sh_path";

    # Windows launcher
    my $bat_path = File::Spec->catfile( $repo_root, 'run_gui.bat' );
    open my $bat_fh, '>', $bat_path or die "Cannot write $bat_path: $!\n";
    print {$bat_fh} <<"BAT";
\@echo off
REM Auto-generated by setup_gui_env.pl -- launches the Cpp Inspector GUI.
"%~dp0gui\\.venv\\Scripts\\python.exe" "%~dp0gui\\app.py"
BAT
    close $bat_fh;
    say "      Wrote $bat_path";

    return;
}

sub check_analysis_tools {
    my @tools   = qw(ctags cscope cqmakedb);
    my @missing = grep { !find_tool_in_path($_) } @tools;
    return unless @missing;

    say "\n[!] Note: the following tool(s) used by cpp_inspector.pl itself"
      . " are not on PATH: "
      . join( ', ', @missing ) . '.';
    say "    The GUI will still launch, but analysis runs will fail until"
      . " they're installed (see the repo root README).";
    return;
}

sub print_summary {
    my ( $repo_root, $gui_dir, $venv_dir ) = @_;
    my $launch_hint =
      $^O eq 'MSWin32' ? 'run_gui.bat' : './run_gui.sh';

    say "\n[SUCCESS] GUI environment ready!";
    say '-' x 50;
    say "Virtualenv:  $venv_dir";
    say "GUI project: $gui_dir";
    say "\nLaunch it with:";
    say "  $launch_hint";
    say "\n...or manually:";
    if ( $^O eq 'MSWin32' ) {
        say "  gui\\.venv\\Scripts\\python.exe gui\\app.py";
    }
    else {
        say "  $venv_dir/bin/python gui/app.py";
    }
    say '-' x 50;
    return;
}
