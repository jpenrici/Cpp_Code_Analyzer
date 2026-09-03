#!/usr/bin/env perl
#
# Name:        cpp_inspector.pl
# Description: Generates a CodeQuery database (.db), a text overview report,
#              a CSV call-relationship export, and an SVG call graph for
#              C/C++ projects by automatically running ctags, cscope and
#              cqmakedb.
#
# Requirements: ctags, cscope, cqmakedb
#
# Reference:
#   https://ruben2020.github.io/codequery/
#

use strict;
use warnings;
use feature 'say';

# Get pathname of current working directory
use Cwd qw(abs_path);

# Supply object methods for filehandles
use File::Basename qw(basename dirname);
use File::Find     qw(find);
use File::Path     qw(make_path);
use File::Spec;

# Extended processing of command line options
use Getopt::Long qw(GetOptions);

# Open a process for reading, writing, and error handling using open3()
use IPC::Open3;

# OO interface to the select system call
use IO::Select;

#JSON::XS compatible pure-Perl module.
use JSON::PP qw(encode_json);

# Manipulate Perl symbols and their names
use Symbol qw(gensym);

use constant {
    SOURCE_EXT_RE  => qr/\.(?:c|cpp|cxx|cc|h|hpp|hxx|hh)$/i,
    SKIP_DIR_RE    => qr/^(?:\.git|\.svn|\.hg|build|cmake-build.*|out)$/i,
    DEFAULT_OUTDIR => 'output'
};

# Kinds we care about when scanning ctags output:
# f=function, c=class, p=prototype, m=member.
my %KIND_LABEL = (
    f => 'Function',
    p => 'Prototype',
    m => 'Member',
    c => 'Class',
);

# Sort priority controls the order in which they appear in the report.
my %KIND_PRIORITY = ( f => 1, p => 2, m => 3, c => 4 );

# Canonical order for --kind selections, LEGEND, and SUMMARY output.
my @ALL_KINDS = qw(f p m c);

# ----------------------------------------------------------------------
# CLI - Entrypoint
# ----------------------------------------------------------------------

sub usage {
    return <<"HELP";
Usage:
  perl $0 [options]

Options:
  --in=<path>      Path to the C++ project directory to scan (default: current directory)
  --out=<path>     Path to the output directory where artifacts will be saved (default: @{[ DEFAULT_OUTDIR ]})
  --config=<path>  Path to the configuration directory (default: project path)
  --kind=<letters> Keep only the given symbol kinds in cpp_relationships.txt (default: fpmc)
                      f=Function  p=Prototype  m=Member  c=Class
                      e.g. --kind=fp keeps functions and prototypes, hides members/classes
  --no_label       Hide the [f/p/m/c] kind label for each symbol in cpp_relationships.txt
  --no_line        Hide the "| Line: N" suffix for each symbol in cpp_relationships.txt
  --no_call        Hide the "Called by:" section in cpp_relationships.txt
  --ignore_config  Ignore config.json even if it is present
  --yes, -y        Skip the confirmation prompt when --out doesn't exist yet
  --serve          Run the dependency-free JSON-lines API server
  --help, -h       Display this help message and exit

Without --serve, the script preserves the interactive CLI behavior.
With --serve, requests are read as JSON objects and responses/events are
written as JSON objects; no confirmation prompt is ever issued.

Server request examples:
  {"id":1,"endpoint":"resolve_paths","params":{"in":"./project","out":"./output"}}
  {"id":2,"endpoint":"load_config","params":{"config_dir":"./project"}}
  {"id":3,"endpoint":"collect","params":{"in":"./project","out":"./output","yes":true}}
  {"id":4,"endpoint":"render","params":{"model":{...},"options":{"kind":"fp"} }}
HELP
}

sub main {
    refuse_to_run_as_root();

    my $opts = parse_arguments(@ARGV);
    if ( $opts->{serve} ) {
        return run_server();
    }

    require_tools_or_die(qw(ctags cscope cqmakedb));
    die usage() if $opts->{in} eq '';

    my $paths = resolve_paths($opts);

    unless ( $opts->{ignore_config} ) {
        my $config = load_config( $paths->{config_dir} );
        emit_cli_events(
            [ make_event( 'info', "Loaded project config: $config->{path}" ) ] )
          if $config->{path};
        emit_cli_events(
            [ map { make_event( 'warning', $_ ) } @{ $config->{warnings} } ] );
        apply_config_defaults( $opts, $config->{values} )
          if %{ $config->{values} };
    }

    $paths = resolve_paths($opts);
    $opts->{yes} ||= 0;

    create_output_dir_if_needed( $paths, $opts->{yes}, 1 );

    my $kind_filter =
      normalize_kind_selection( $opts->{kind} // join( '', @ALL_KINDS ) );

    say "[*] Scanning project directory: $paths->{project_dir}";
    say "[*] Saving output artifacts to: $paths->{output_dir}";
    say "[*] Current Config directory: $paths->{config_dir}"
      unless $opts->{ignore_config};
    say "[*] Current commands: "
      . ( $opts->{no_label}      ? " --no_label"                 : "" )
      . ( $opts->{no_line}       ? " --no_line"                  : "" )
      . ( $opts->{no_call}       ? " --no_call"                  : "" )
      . ( $opts->{ignore_config} ? " --ignore_config"            : "" )
      . ( $kind_filter ? " --kinds=" . join( '', @$kind_filter ) : "" )
      . ( $opts->{yes} ? " --yes"                                : "" ) . "\n";

    $opts->{paths} = $paths;
    $opts->{emit}  = \&emit_cli_event;

    my $collected = collect($opts);

    my $rendered = render( $collected->{model}, $opts );
    print_summary(
        $rendered->{artifact_paths}{db},  $rendered->{artifact_paths}{text},
        $rendered->{artifact_paths}{csv}, $rendered->{artifact_paths}{json},
        $rendered->{artifact_paths}{svg}
    );
    return;
}

sub refuse_to_run_as_root {
    return unless $> == 0;
    die "Error: Running this script as 'root'"
      . " is not allowed for security reasons.\n"
      . "Please run it as a normal user.\n";
}

# ----------------------------------------------------------------------
# Dependency-free JSON-lines server
# ----------------------------------------------------------------------

# The server protocol is deliberately small so the script remains a single
# file with no web framework dependency:
#
# Request:
#   {"id": 1, "endpoint": "resolve_paths", "params": {...}}
#
# Response:
#   {"id": 1, "type": "response", "ok": true, "data": {...}}
#
# Event:
#   {"id": 1, "type": "event", ...}
#
# Errors use the same envelope with ok=false. STDIN is a request transport,
# NEVER an interactive confirmation channel.
sub server_write {
    my ($value) = @_;
    print encode_json($value), "\n";
}

sub run_server {
    while ( my $line = <STDIN> ) {
        chomp $line;
        next unless length $line;

        my $request = eval { JSON::PP->new->decode($line) };
        if ( $@ || ref($request) ne 'HASH' ) {
            server_write(
                {
                    type  => 'response',
                    ok    => JSON::PP::false,
                    error => 'Invalid JSON request.',
                }
            );
            next;
        }

        my $id       = $request->{id};
        my $endpoint = $request->{endpoint} // '';
        my $params   = $request->{params};
        $params = {} unless ref($params) eq 'HASH';

        if ( $endpoint eq 'collect' ) {
            run_server_collect_job( $id, $params );
            next;
        }

        my $result = eval {
            if ( $endpoint eq 'resolve_paths' ) {
                return resolve_paths($params);
            }
            if ( $endpoint eq 'load_config' ) {
                my $config_dir = $params->{config_dir} // '';
                return load_config($config_dir);
            }
            if ( $endpoint eq 'render' ) {
                my $model   = $params->{model};
                my $options = $params->{options} // {};
                return render( $model, $options );
            }
            die "Unknown endpoint '$endpoint'.\n";
        };

        if ($@) {
            server_write(
                {
                    id    => $id,
                    type  => 'response',
                    ok    => JSON::PP::false,
                    error => "$@",
                }
            );
            next;
        }

        server_write(
            {
                id   => $id,
                type => 'response',
                ok   => JSON::PP::true,
                data => $result,
            }
        );
    }
}

sub run_server_collect_job {
    my ( $id, $params ) = @_;

    my ( $reader, $writer );
    pipe( $reader, $writer )
      or die "Error: cannot create collect job pipe: $!\n";

    my $pid = fork();
    die "Error: cannot fork collect job: $!\n" unless defined $pid;

    if ( $pid == 0 ) {
        close $reader;
        select( ( select($writer), $| = 1 )[0] );

        my $payload;
        my $ok = eval {
            require_tools_or_die(qw(ctags cscope cqmakedb));

            my $paths = resolve_paths($params);
            if ( $paths->{needs_output_creation} ) {
                die "Confirmation required: "
                  . "output directory '$paths->{output_dir}' "
                  . "does not exist. Call again with yes=true.\n"
                  unless $params->{yes};
                make_path( $paths->{output_dir} );
                $paths->{output_dir} = abs_path( $paths->{output_dir} );
            }
            $params->{paths} = $paths;

            $params->{emit} = sub {
                my ($event) = @_;
                print {$writer} encode_json( { %$event, id => $id } ), "\n";
            };

            $payload = collect($params);
            1;
        };

        if ($ok) {
            delete $payload->{events};
            print {$writer} encode_json(
                {
                    id   => $id,
                    type => 'response',
                    ok   => JSON::PP::true,
                    data => $payload,
                }
              ),
              "\n";
        }
        else {
            print {$writer} encode_json(
                {
                    id    => $id,
                    type  => 'response',
                    ok    => JSON::PP::false,
                    error => "$@",
                }
              ),
              "\n";
        }

        close $writer;
        exit( $ok ? 0 : 1 );
    }

    close $writer;
    server_write(
        {
            id       => $id,
            type     => 'job_started',
            ok       => JSON::PP::true,
            job_id   => "$pid",
            endpoint => 'collect',
        }
    );

    while ( my $event_line = <$reader> ) {
        chomp $event_line;
        my $event = eval { JSON::PP->new->decode($event_line) };
        if ( $@ || ref($event) ne 'HASH' ) {
            server_write(
                {
                    id    => $id,
                    type  => 'response',
                    ok    => JSON::PP::false,
                    error => 'Invalid internal collect event.',
                }
            );
            next;
        }
        server_write($event);
    }

    close $reader;
    waitpid( $pid, 0 );
}

sub emit_server_collect_events {
    my ( $id, $events ) = @_;
    for my $event (@$events) {
        server_write( { %$event, id => $id } );
    }
}

# ----------------------------------------------------------------------
# Common Event Shape
# ----------------------------------------------------------------------

# A single structured event shape is used by every frontend:
#   { type => "event", step => N, total => N, message => "...",
#     level => "info|warning|error|tool_output", ... }
#
# Core functions never print progress. They return events; the frontend owns
# the transport (terminal, TUI, HTTP adapter, etc.).
sub make_event {
    my ( $level, $message, %extra ) = @_;
    return {
        type    => 'event',
        level   => $level,
        message => $message,
        %extra,
    };
}

sub emit_cli_event {
    my ($event) = @_;
    return unless ref($event) eq 'HASH';

    my $level = $event->{level} // 'info';
    if ( $level eq 'tool_output' ) {
        return if ( $event->{context} // '' ) eq 'caller_query';

        my $stream = $event->{stream} // 'stdout';
        my $data   = $event->{data}   // '';
        return unless length $data;

        if ( $stream eq 'stderr' ) {
            print STDERR $data;
        }
        else {
            print $data;
        }
        return;
    }

    my $step  = $event->{step};
    my $total = $event->{total};
    if ( defined $step && defined $total ) {
        say sprintf( '[%d/%d] %s', $step, $total, $event->{message} // '' );
    }
    elsif ( $level eq 'warning' ) {
        warn( $event->{message} // '' ) . "\n";
    }
    elsif ( $level eq 'error' ) {
        warn( $event->{message} // '' ) . "\n";
    }
    else {
        say $event->{message} // '';
    }
}

sub emit_cli_events {
    my ($events) = @_;
    emit_cli_event($_) for @$events;
}

# ----------------------------------------------------------------------
# Frontend - API
# ----------------------------------------------------------------------

# Resolves project/output/config paths without creating directories or asking
# questions. The caller decides whether a pending confirmation is acceptable.
sub resolve_paths {
    my ($params) = @_;
    $params //= {};

    my $raw_project = $params->{in} // '';
    die "Error: project path is required.\n" unless length $raw_project;
    $raw_project = glob($raw_project) if $raw_project =~ /^~/;

    my $project_dir = abs_path($raw_project)
      or die "Error: Invalid project directory path: $raw_project\n";
    die "Error: The project directory '$project_dir' does not exist.\n"
      unless -d $project_dir;

    my $raw_output = defined $params->{out} ? $params->{out} : DEFAULT_OUTDIR;
    $raw_output = glob($raw_output) if $raw_output =~ /^~/;
    my $output_abs    = File::Spec->rel2abs($raw_output);
    my $output_exists = -d $raw_output ? 1 : 0;

    my $config_dir = '';
    unless ( $params->{ignore_config} ) {
        $config_dir =
          length( $params->{config_dir} // '' )
          ? $params->{config_dir}
          : $project_dir;
        $config_dir = glob($config_dir) if $config_dir =~ /^~/;
        $config_dir = abs_path($config_dir) // $config_dir;
    }

    return {
        project_dir   => $project_dir,
        output_dir    => $output_exists ? abs_path($raw_output) : $output_abs,
        config_dir    => $config_dir,
        output_exists => $output_exists,
        needs_output_creation => $output_exists ? 0 : 1,
        confirmation          => $output_exists
        ? undef
        : {
            required => 1,
            action   => 'create_output_dir',
            path     => $output_abs,
        },
    };
}

# Pure config reader: no printing, warnings, prompting, or other UI effects.
# Returns { values => {...}, warnings => [...] }.
sub load_config {
    my ($config_dir) = @_;
    return { values => {}, warnings => [] }
      unless defined $config_dir && -d $config_dir;

    my $config_path = File::Spec->catfile( $config_dir, 'config.json' );
    return { values => {}, warnings => [] } unless -f $config_path;

    open my $fh, '<', $config_path
      or die "Cannot open $config_path: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh or die "Cannot close $config_path: $!\n";

    my $data = eval { JSON::PP->new->decode($raw) };
    die "Error: invalid JSON in $config_path: $@\n" if $@;
    die "Error: $config_path must contain a JSON object.\n"
      unless ref($data) eq 'HASH';

    my %known = map { $_ => 1 } qw(out kind no_line no_label no_call yes);
    my %values;
    my @warnings;
    for my $key ( sort keys %$data ) {
        if ( !$known{$key} ) {
            push @warnings,
              "Warning: unknown key '$key' in $config_path (ignored).";
            next;
        }
        $values{$key} = $data->{$key};
    }

    return {
        values   => \%values,
        warnings => \@warnings,
        path     => $config_path,
    };
}

sub load_project_config {
    my ($config_dir) = @_;
    return load_config($config_dir)->{values};
}

sub apply_config_defaults {
    my ( $opts, $config ) = @_;
    return unless ref($config) eq 'HASH' && %$config;

    for my $bool_key (qw(no_line no_label no_call yes)) {
        next if $opts->{$bool_key};
        next unless exists $config->{$bool_key};
        $opts->{$bool_key} = $config->{$bool_key} ? 1 : 0;
    }
    $opts->{out} = $config->{out}
      if !defined $opts->{out} && defined $config->{out};
    $opts->{kind} = $config->{kind}
      if !defined $opts->{kind} && defined $config->{kind};
}

sub confirm_or_die {
    my ( $prompt, $decision ) = @_;

    return if defined $decision && $decision;

    print $prompt;
    my $answer = <STDIN>;
    $answer = defined $answer ? lc($answer) : 'n';
    chomp $answer;

    die "Aborted: output directory was not created.\n"
      unless $answer =~ /^y(es)?$/;
    return;
}

sub create_output_dir_if_needed {
    my ( $paths, $decision, $interactive ) = @_;
    return $paths->{output_dir} unless $paths->{needs_output_creation};

    if ($interactive) {
        confirm_or_die(
            "[?] Output directory does not exist: $paths->{output_dir}\n"
              . "    Create it now? [y/N] ",
            $decision
        );
    }
    else {
        die "Error: output directory '$paths->{output_dir}' does not exist "
          . "and no confirmation decision was supplied.\n"
          unless defined $decision && $decision;
    }

    make_path( $paths->{output_dir} );
    return abs_path( $paths->{output_dir} );
}

sub find_tool_in_path {
    my ($tool) = @_;
    for my $dir ( split /:/, $ENV{PATH} // '' ) {
        my $candidate = File::Spec->catfile( $dir, $tool );
        return $candidate if -x $candidate && !-d $candidate;
    }
    return undef;
}

sub require_tools_or_die {
    my @tools   = @_;
    my @missing = grep { !find_tool_in_path($_) } @tools;
    return unless @missing;
    die "Error: The following required tool(s) are missing from your PATH: "
      . join( ', ', @missing )
      . ".\nPlease install them before running the script.\n";
}

sub parse_arguments {
    local @ARGV = @_;
    my %opts = (
        in            => '',
        out           => undef,
        config_dir    => '',
        no_line       => 0,
        no_label      => 0,
        no_call       => 0,
        ignore_config => 0,
        kind          => undef,
        yes           => 0,
        serve         => 0,
    );
    GetOptions(
        'in=s'          => \$opts{in},
        'out=s'         => \$opts{out},
        'config=s'      => \$opts{config_dir},
        'no_line'       => \$opts{no_line},
        'no_label'      => \$opts{no_label},
        'no_call'       => \$opts{no_call},
        'ignore_config' => \$opts{ignore_config},
        'kind=s'        => \$opts{kind},
        'yes|y'         => \$opts{yes},
        'serve'         => \$opts{serve},
        'help|h'        => sub { print usage(); exit 0; },
    ) or die usage();
    return \%opts;
}

sub normalize_kind_selection {
    my ($raw)     = @_;
    my %requested = map  { $_ => 1 } split //, lc( $raw // '' );
    my @invalid   = grep { !exists $KIND_LABEL{$_} } keys %requested;
    die "Error: invalid --kind value(s): "
      . join( ', ', sort @invalid )
      . ". Valid kinds are: "
      . join( ' ', @ALL_KINDS ) . ".\n"
      if @invalid;
    die "Error: --kind must include at least one of: "
      . join( ' ', @ALL_KINDS ) . ".\n"
      unless %requested;
    return [ grep { $requested{$_} } @ALL_KINDS ];
}

# ----------------------------------------------------------------------
# Collection and Rendering
# ----------------------------------------------------------------------

sub collect_source_files {
    my ($project_dir) = @_;
    my @source_files;
    find(
        {
            wanted => sub {
                if ( -d $_ ) {
                    my $dir_name = basename($_);
                    if ( $dir_name =~ /@{[ SKIP_DIR_RE ]}/ ) {
                        $File::Find::prune = 1;
                        return;
                    }
                }
                push @source_files, abs_path($_)
                  if -f $_ && /@{[ SOURCE_EXT_RE ]}/;
            },
            no_chdir => 1,
        },
        $project_dir
    );
    return sort @source_files;
}

sub write_file_list {
    my ( $path, $files ) = @_;
    open my $fh, '>', $path or die "Could not create $path: $!\n";
    print {$fh} "$_\n" for @$files;
    close $fh or die "Could not write $path: $!\n";
}

sub run_tool_capture {
    my ( $tool, @args ) = @_;

    my $stderr_fh = gensym();
    my ( $stdin_fh, $stdout_fh );
    my $pid = eval { open3( $stdin_fh, $stdout_fh, $stderr_fh, $tool, @args ) };
    die "Error: failed to start $tool: $@\n" if $@ || !defined $pid;
    close $stdin_fh;

    my $selector    = IO::Select->new( $stdout_fh, $stderr_fh );
    my %stream_name = (
        fileno($stdout_fh) => 'stdout',
        fileno($stderr_fh) => 'stderr',
    );
    my %buffers = ( stdout => '', stderr => '' );
    my %fds     = map { fileno($_) => $_ } ( $stdout_fh, $stderr_fh );

    while ( $selector->count ) {
        for my $fh ( $selector->can_read ) {
            my $fd    = fileno($fh);
            my $name  = $stream_name{$fd} // 'stdout';
            my $chunk = '';
            my $bytes = sysread( $fh, $chunk, 64 * 1024 );

            if ( defined $bytes && $bytes > 0 ) {
                $buffers{$name} .= $chunk;
            }
            else {
                $selector->remove($fh);
                close $fh;
                delete $fds{$fd};
            }
        }
    }

    waitpid( $pid, 0 );
    my $status = $?;
    return {
        tool      => $tool,
        stdout    => $buffers{stdout},
        stderr    => $buffers{stderr},
        exit_code => $status == -1 ? -1 : ( $status >> 8 ),
        signal    => $status & 127,
    };
}

sub tool_result_events {
    my ($result) = @_;
    my @events;
    for my $stream (qw(stdout stderr)) {
        next unless length( $result->{$stream} // '' );
        push @events,
          make_event(
            'tool_output',
            "$result->{tool} $stream",
            tool   => $result->{tool},
            stream => $stream,
            data   => $result->{$stream},
            (
                defined $result->{context}
                ? ( context => $result->{context} )
                : ()
            ),
          );
    }
    return @events;
}

sub run_ctags {
    my ( $cscope_files_path, $tags_path ) = @_;
    return run_tool_capture( 'ctags', '-R', '--c++-kinds=+p', '--fields=+iaSt',
        '-n', '-L', $cscope_files_path, '-f', $tags_path );
}

sub run_cscope {
    my ( $cscope_files_path, $cscope_out_path ) = @_;
    return run_tool_capture( 'cscope', '-b', '-c', '-q', '-i',
        $cscope_files_path, '-f', $cscope_out_path );
}

sub run_cqmakedb {
    my ( $db_path, $cscope_out_path, $tags_path ) = @_;
    return run_tool_capture( 'cqmakedb', '-s', $db_path, '-c', $cscope_out_path,
        '-t', $tags_path, '-p' );
}

sub collect {
    my ($params) = @_;
    $params //= {};

    my $paths      = $params->{paths} // resolve_paths($params);
    my $output_dir = $paths->{output_dir};

    my $kind_filter =
      normalize_kind_selection( $params->{kind} // join( '', @ALL_KINDS ) );

    my @events;
    my $emit = ref( $params->{emit} ) eq 'CODE' ? $params->{emit} : sub {
        push @events, $_[0];
    };

    my @source_files = collect_source_files( $paths->{project_dir} );
    my $total_files  = scalar @source_files;

    $emit->(
        make_event(
            'info', "Found $total_files C/C++ source/header files.",
            step  => 1,
            total => 8
        )
    );

    die "No C/C++ files found in '$paths->{project_dir}'.\n"
      unless $total_files;

    my $cscope_files_path = File::Spec->catfile( $output_dir, 'cscope.files' );
    write_file_list( $cscope_files_path, \@source_files );
    $emit->(
        make_event(
            'info', "Wrote absolute file list to 'cscope.files'.",
            step  => 2,
            total => 8
        )
    );

    my $tags_path       = File::Spec->catfile( $output_dir, 'tags' );
    my $cscope_out_path = File::Spec->catfile( $output_dir, 'cscope.out' );
    my $db_path         = File::Spec->catfile( $output_dir, 'codequery.db' );
    my $report_path     = File::Spec->catfile( $output_dir,
        report_filename( $params, $kind_filter, 'txt' ) );
    my $csv_path  = File::Spec->catfile( $output_dir, 'cpp_relationships.csv' );
    my $json_path = File::Spec->catfile( $output_dir,
        report_filename( $params, $kind_filter, 'json' ) );
    my $svg_path = File::Spec->catfile( $output_dir, 'cpp_call_graph.svg' );

    my @tool_runs = (
        [
            3,           'Running ctags...',
            \&run_ctags, [ $cscope_files_path, $tags_path ]
        ],
        [
            4,            'Running cscope...',
            \&run_cscope, [ $cscope_files_path, $cscope_out_path ]
        ],
        [
            5,              'Generating CodeQuery database (.db)...',
            \&run_cqmakedb, [ $db_path, $cscope_out_path, $tags_path ]
        ],
    );

    for my $run (@tool_runs) {
        my ( $step, $message, $runner, $args ) = @$run;
        $emit->( make_event( 'info', $message, step => $step, total => 8 ) );
        my $result = $runner->(@$args);
        $emit->($_) for tool_result_events($result);

        if ( $result->{exit_code} != 0 ) {
            if ( $step == 5 ) {
                die "Critical Error: cqmakedb exited"
                  . " with status $result->{exit_code}.\n";
            }
            $emit->(
                make_event(
                    'warning',
                    "$result->{tool} exited with a non-zero"
                      . " status ($result->{exit_code}).",
                    step  => $step,
                    total => 8
                )
            );
        }
    }

    $emit->(
        make_event( 'info', 'Parsing tags output.', step => 6, total => 8 ) );
    my %definitions = parse_tags($tags_path);

    $emit->(
        make_event(
            'info',
            'Mapping caller/callee relationships via cscope.',
            step  => 7,
            total => 8
        )
    );
    my %callers_of = build_caller_map( \%definitions, $cscope_out_path, $emit );

    my $model = {
        project_dir    => $paths->{project_dir},
        output_dir     => $output_dir,
        source_files   => \@source_files,
        definitions    => \%definitions,
        callers_of     => \%callers_of,
        kind_filter    => $kind_filter,
        artifact_paths => {
            db           => $db_path,
            text         => $report_path,
            csv          => $csv_path,
            json         => $json_path,
            svg          => $svg_path,
            cscope_files => $cscope_files_path,
            tags         => $tags_path,
            cscope_out   => $cscope_out_path,
        },
    };

    $emit->(
        make_event(
            'info',
            'Writing text, CSV, JSON and SVG reports.',
            step  => 8,
            total => 8
        )
    );

    return { model => $model, events => \@events };
}

sub render {
    my ( $model, $options ) = @_;
    die "Error: render requires a collected model.\n"
      unless ref($model) eq 'HASH';
    $options //= {};

    my $kind_filter =
      normalize_kind_selection( $options->{kind} // join( '', @ALL_KINDS ) );
    my $format = {
        hide_labels    => $options->{no_label} ? 1 : 0,
        hide_lines     => $options->{no_line}  ? 1 : 0,
        hide_called_by => $options->{no_call}  ? 1 : 0,
        kind           => $kind_filter,
    };

    my $output_dir = $model->{output_dir};
    my $paths      = {
        db   => File::Spec->catfile( $output_dir, 'codequery.db' ),
        text => File::Spec->catfile(
            $output_dir, report_filename( $options, $kind_filter, 'txt' )
        ),
        csv  => File::Spec->catfile( $output_dir, 'cpp_relationships.csv' ),
        json => File::Spec->catfile(
            $output_dir, report_filename( $options, $kind_filter, 'json' )
        ),
        svg => File::Spec->catfile( $output_dir, 'cpp_call_graph.svg' ),
    };

    write_text_report( $paths->{text}, $model->{definitions},
        $model->{callers_of}, $model->{project_dir}, $format );
    write_csv_report( $paths->{csv}, $model->{callers_of},
        $model->{project_dir} );
    write_json_report( $paths->{json}, $model->{definitions},
        $model->{callers_of}, $model->{project_dir}, $format );
    write_svg_call_graph( $paths->{svg}, $model->{callers_of} );

    return {
        options        => $format,
        artifact_paths => $paths,
    };
}

sub report_filename {
    my ( $opts, $kind_filter, $extension ) = @_;
    my @suffix;
    push @suffix, 'kind_' . join( '', @$kind_filter )
      if @$kind_filter != @ALL_KINDS;
    push @suffix, 'no_label' if $opts->{no_label};
    push @suffix, 'no_line'  if $opts->{no_line};
    push @suffix, 'no_call'  if $opts->{no_call};
    my $name = 'cpp_relationships';
    $name .= '__' . join( '__', @suffix ) if @suffix;
    return "$name.$extension";
}

# ----------------------------------------------------------------------
# Ctags parsing
# ----------------------------------------------------------------------

# Returns %definitions{file}{symbol_name} = { kind, line, signature }
sub parse_tags {
    my ($tags_path) = @_;

    my %definitions;
    open my $fh, '<', $tags_path or die "[-] Cannot open tags file: $!\n";
    while ( my $line = <$fh> ) {
        next if $line =~ /^!/;
        chomp $line;

        my ( $name, $file, $line_num, $kind, @rest ) = split /\t/, $line;
        next unless defined $kind && exists $KIND_LABEL{$kind};

        ($line_num) = $line_num =~ /(\d+)/;    # strip ;" and other artifacts

        my ($signature) = map { /^signature:(.*)/ ? $1 : () } @rest;
        $signature //= '';

        my ($return_type) = map { /^typeref:[^:]+:(.*)/ ? $1 : () } @rest;

        my ($scope) =
          map { /^(?:class|struct|namespace|union):(.*)/ ? $1 : () } @rest;

        $definitions{$file}{$name} = {
            kind        => $kind,
            line        => $line_num,
            signature   => $signature,
            return_type => $return_type,
            scope       => $scope,
        };
    }
    close $fh;

    return %definitions;
}

# ----------------------------------------------------------------------
# Call graph construction
# ----------------------------------------------------------------------

# For every known symbol, ask cscope "who calls this function?"
# (cscope line-mode -L -3), and record the callers keyed by callee.
sub build_caller_map {
    my ( $definitions, $cscope_out_path, $emit ) = @_;
    $emit = sub { }
      unless ref($emit) eq 'CODE';

    my %callers_of;    # callee_name => [ { caller, file, line }, ... ]

    for my $file ( keys %$definitions ) {
        for my $func_name ( keys %{ $definitions->{$file} } ) {
            next if $definitions->{$file}{$func_name}{kind} eq 'c';

            my ( $callers, $tool_result ) =
              find_callers( $cscope_out_path, $func_name );
            $emit->($_)
              for tool_result_events(
                {
                    %$tool_result, context => 'caller_query',
                }
              );
            push @{ $callers_of{$func_name} }, @$callers if @$callers;
        }
    }

    return %callers_of;
}

# cscope is also invoked while constructing the call map. It therefore uses
# the same explicit stdout/stderr capture path as the top-level tool runs,
# preventing any external process from writing directly to a frontend.
sub find_callers {
    my ( $cscope_out_path, $func_name ) = @_;

    my $result =
      run_tool_capture( 'cscope', '-d', '-f', $cscope_out_path, '-L', '-3',
        $func_name );

    my @callers;
    for my $line ( split /\n/, $result->{stdout} // '' ) {

        # cscope -L output format: file caller_function line_number code
        next unless $line =~ /^(\S+)\s+(\S+)\s+(\d+)\s+(.*)$/;
        my ( $file, $caller_func, $call_line, undef ) = ( $1, $2, $3, $4 );
        next if $caller_func eq $func_name;
        push @callers,
          { caller => $caller_func, file => $file, line => $call_line };
    }

    return ( \@callers, $result );
}

# ----------------------------------------------------------------------
# Report generation
# ----------------------------------------------------------------------

# JSON export optimized for machine/AI consumption.
#
# Top-level structure:
# {
#   schema_version: "1.0",
#   project: {...},
#   options: { kind, hide_labels, hide_lines, hide_called_by },
#   summary: {...},
#   files: [ { path, symbols: [ { name, kind, kind_name, line, signature,
#                                 return_type, callers: [...] } ] } ],
#   relationships: [ { callee, caller, file, line } ]
# }
sub write_json_report {
    my ( $json_path, $definitions, $callers_of, $project_dir, $format ) = @_;

    die "[-] Invalid arguments to write_json_report\n"
      unless defined $json_path
      && ref($definitions) eq 'HASH'
      && ref($callers_of) eq 'HASH';

    $format //= {};
    my $hide_labels    = $format->{hide_labels};
    my $hide_lines     = $format->{hide_lines};
    my $hide_called_by = $format->{hide_called_by};
    my $kind_filter    = $format->{kind} // \@ALL_KINDS;
    my %allowed_kind   = map { $_ => 1 } @$kind_filter;

    my $path_base = defined $project_dir ? dirname($project_dir) : undef;

    my %kind_of_name;
    for my $file ( sort keys %$definitions ) {
        for my $name ( keys %{ $definitions->{$file} } ) {
            $kind_of_name{$name} //= $definitions->{$file}{$name}{kind};
        }
    }

    my %counts;
    my $total_symbols = 0;
    my @files;

    for my $file ( sort keys %$definitions ) {
        my @names =
          grep { $allowed_kind{ $definitions->{$file}{$_}{kind} } }
          sorted_symbol_names( $definitions->{$file} );
        next unless @names;    # skip files with nothing left after filtering

        my @symbols;
        for my $name (@names) {
            my $info = $definitions->{$file}{$name};
            my $kind = $info->{kind};
            $counts{$kind}++;
            $total_symbols++;

            my $qualified_name =
              ( defined $info->{scope} && length $info->{scope} )
              ? "$info->{scope}::$name"
              : $name;
            my %symbol = ( name => $name, qualified_name => $qualified_name );

            unless ($hide_labels) {
                $symbol{kind}      = $kind;
                $symbol{kind_name} = $KIND_LABEL{$kind} // '';
            }
            unless ($hide_lines) {
                $symbol{line} = 0 + ( $info->{line} // 0 );
            }
            if ( defined $info->{signature} && length $info->{signature} ) {
                $symbol{signature} = $info->{signature};
            }
            if ( defined $info->{return_type}
                && length $info->{return_type} )
            {
                $symbol{return_type} = $info->{return_type};
            }

            my @callers;
            unless ($hide_called_by) {
                my %seen_callers;
                for my $call ( @{ $callers_of->{$name} // [] } ) {
                    next unless ref($call) eq 'HASH';
                    my $caller = $call->{caller} // '';
                    next if $seen_callers{$caller}++;

                    my %caller_entry = (
                        name => $caller,
                        file => shorten_path( $call->{file} // '', $path_base ),
                    );
                    $caller_entry{line} = 0 + ( $call->{line} // 0 )
                      unless $hide_lines;

                    push @callers, \%caller_entry;
                }
            }
            $symbol{callers} = \@callers;

            push @symbols, \%symbol;
        }

        push @files,
          {
            path    => shorten_path( $file, $path_base ),
            symbols => \@symbols,
          };
    }

    my @relationships;
    my $total_relationships = 0;
    unless ($hide_called_by) {
        my %seen_relationships;
        for my $callee ( sort keys %$callers_of ) {
            next
              if exists $kind_of_name{$callee}
              && !$allowed_kind{ $kind_of_name{$callee} };

            for my $call ( @{ $callers_of->{$callee} // [] } ) {
                next unless ref($call) eq 'HASH';

                my $caller = $call->{caller} // '';
                my $file   = $call->{file}   // '';
                my $line   = 0 + ( $call->{line} // 0 );

                my $key = join "\0", $callee, $caller, $file, $line;
                next if $seen_relationships{$key}++;

                my %relationship = (
                    callee => $callee,
                    caller => $caller,
                    file   => shorten_path( $file, $path_base ),
                );
                $relationship{line} = $line unless $hide_lines;

                push @relationships, \%relationship;
                $total_relationships++;
            }
        }
    }

    my %report = (
        schema_version => '1.0',

        project => {
            path => defined $project_dir
            ? shorten_path( $project_dir, $path_base )
            : '',
        },

        options => {
            kind           => $kind_filter,
            hide_labels    => $hide_labels ? JSON::PP::true : JSON::PP::false,
            hide_lines     => $hide_lines  ? JSON::PP::true : JSON::PP::false,
            hide_called_by => $hide_called_by
            ? JSON::PP::true
            : JSON::PP::false,
        },

        summary => {
            files         => scalar(@files),
            symbols       => $total_symbols,
            relationships => $total_relationships,

            kinds => {
                function  => 0 + ( $counts{f} // 0 ),
                prototype => 0 + ( $counts{p} // 0 ),
                member    => 0 + ( $counts{m} // 0 ),
                class     => 0 + ( $counts{c} // 0 ),
            },
        },

        files         => \@files,
        relationships => \@relationships,
    );

    open my $fh, '>', $json_path
      or die "[-] Cannot open JSON analysis file: $!\n";
    print {$fh} JSON::PP->new->utf8->canonical->pretty->encode( \%report );
    close $fh
      or die "[-] Cannot write JSON analysis file: $!\n";

    return;
}

sub write_text_report {
    my ( $report_path, $definitions, $callers_of, $project_dir, $format ) = @_;
    $format //= {};
    my $hide_labels    = $format->{hide_labels};
    my $hide_lines     = $format->{hide_lines};
    my $hide_called_by = $format->{hide_called_by};
    my $kind_filter    = $format->{kind} // \@ALL_KINDS;
    my %allowed_kind   = map { $_ => 1 } @$kind_filter;

    my $path_base = defined $project_dir ? dirname($project_dir) : undef;

    open my $fh, '>', $report_path
      or die "[-] Cannot open text analysis file: $!\n";

    print {$fh} "=== C++ PROJECT RELATIONSHIPS OVERVIEW ===\n\n";

    unless ($hide_labels) {
        print {$fh} "LEGEND:\n";
        for my $kind (@$kind_filter) {
            printf {$fh} "  [%s] %-10s - %s\n", $kind, $KIND_LABEL{$kind},
              kind_description($kind);
        }
        print {$fh} ( '=' x 50 ) . "\n\n";
    }

    my %counts = count_kinds($definitions);
    print {$fh} "SUMMARY:\n";
    my $total = 0;
    for my $kind (@$kind_filter) {
        my $n = $counts{$kind} // 0;
        $total += $n;
        printf {$fh} "  [%s] %-10s : %d\n", $kind, $KIND_LABEL{$kind}, $n;
    }
    printf {$fh} "  %-14s : %d\n", 'Total', $total;
    print {$fh} ( '=' x 50 ) . "\n\n";

    for my $file ( sort keys %$definitions ) {
        my @names =
          grep { $allowed_kind{ $definitions->{$file}{$_}{kind} } }
          sorted_symbol_names( $definitions->{$file} );
        next unless @names;    # skip files with nothing left after filtering

        print {$fh} "FILE: " . shorten_path( $file, $path_base ) . "\n";

        for my $name (@names) {
            my $info = $definitions->{$file}{$name};

            my @parts;
            push @parts, "[$info->{kind}]" unless $hide_labels;
            push @parts, $info->{return_type}
              if $info->{kind} =~ /^[fp]$/
              && defined $info->{return_type}
              && length $info->{return_type};
            push @parts, $name;
            push @parts, $info->{signature} if length $info->{signature};
            push @parts, "| Line: $info->{line}" unless $hide_lines;
            print {$fh} '  ' . join( ' ', @parts ) . "\n";

            next if $hide_called_by;
            next unless exists $callers_of->{$name};

            print {$fh} "    Called by:\n";
            my %seen;
            for my $call ( @{ $callers_of->{$name} } ) {
                next if $seen{ $call->{caller} }++;
                my $call_file = shorten_path( $call->{file}, $path_base );
                print {$fh}
                  "      <- $call->{caller} | at $call_file:$call->{line}\n";
            }
        }
        print {$fh} "\n" . ( '-' x 40 ) . "\n\n";
    }

    close $fh;
    return;
}

sub shorten_path {
    my ( $path, $base_dir ) = @_;
    return $path unless defined $path && defined $base_dir;

    my $relative = eval { File::Spec->abs2rel( $path, $base_dir ) };
    return ( defined $relative && length $relative ) ? $relative : $path;
}

sub count_kinds {
    my ($definitions) = @_;
    my %counts;
    for my $file ( keys %$definitions ) {
        for my $name ( keys %{ $definitions->{$file} } ) {
            $counts{ $definitions->{$file}{$name}{kind} }++;
        }
    }
    return %counts;
}

sub kind_description {
    my ($kind) = @_;
    my %desc = (
        f => 'Function definition',
        p => 'Function or method declaration',
        m => 'Class member variable or method',
        c => 'Class or struct definition',
    );
    return $desc{$kind} // '';
}

sub sorted_symbol_names {
    my ($file_defs) = @_;
    return sort {
        my $p_a = $KIND_PRIORITY{ $file_defs->{$a}{kind} } // 99;
        my $p_b = $KIND_PRIORITY{ $file_defs->{$b}{kind} } // 99;
        $p_a <=> $p_b || $a cmp $b
    } keys %$file_defs;
}

# CSV export: one row per unique (callee, caller) edge, easy to load into
# spreadsheets or graph-analysis tools.
sub write_csv_report {
    my ( $csv_path, $callers_of, $project_dir ) = @_;

    open my $fh, '>', $csv_path or die "[-] Cannot open CSV file: $!\n";
    print {$fh} "callee,caller,file,line\n";

    for my $callee ( sort keys %$callers_of ) {
        my %seen;
        for my $call ( @{ $callers_of->{$callee} } ) {
            my $key = "$call->{caller}\0$call->{file}\0$call->{line}";
            next if $seen{$key}++;

            my $path_base =
              defined $project_dir ? dirname($project_dir) : undef;
            my $file = shorten_path( $call->{file}, $path_base );

            print {$fh} join( ',',
                csv_escape($callee), csv_escape( $call->{caller} ),
                csv_escape($file),   csv_escape( $call->{line} ),
              ),
              "\n";
        }
    }

    close $fh;
    return;
}

sub csv_escape {
    my ($value) = @_;
    $value //= '';
    if ( $value =~ /[",\n]/ ) {
        $value =~ s/"/""/g;
        return qq{"$value"};
    }
    return $value;
}

# SVG export: a lightweight, dependency-free circular call graph.
# Nodes are the functions that participate in at least one call edge;
# edges are drawn as straight lines with an arrowhead at the callee.
sub write_svg_call_graph {
    my ( $svg_path, $callers_of ) = @_;

    my %nodes;
    my @edges;    # [ caller, callee ]
    for my $callee ( keys %$callers_of ) {
        my %seen;
        for my $call ( @{ $callers_of->{$callee} } ) {
            next if $seen{ $call->{caller} }++;
            $nodes{$callee}++;
            $nodes{ $call->{caller} }++;
            push @edges, [ $call->{caller}, $callee ];
        }
    }

    open my $fh, '>', $svg_path or die "[-] Cannot open SVG file: $!\n";

    unless (%nodes) {
        print {$fh}
          svg_wrap( '<text x="20" y="30" font-family="sans-serif" '
              . 'font-size="14">No call relationships were found.</text>' );
        close $fh;
        return;
    }

    my @names  = sort keys %nodes;
    my $count  = scalar @names;
    my $radius = 120 + 12 * $count;
    my ( $cx, $cy ) = ( $radius + 60, $radius + 60 );
    my $size = 2 * $radius + 120;

    my %pos;
    for my $i ( 0 .. $#names ) {
        my $angle = 2 * 3.14159265 * $i / $count;
        $pos{ $names[$i] } = {
            x => $cx + $radius * cos($angle),
            y => $cy + $radius * sin($angle),
        };
    }

    my @svg_parts;
    push @svg_parts, marker_def();

    for my $edge (@edges) {
        my ( $caller, $callee ) = @$edge;
        my ( $x1,     $y1 )     = @{ $pos{$caller} }{qw(x y)};
        my ( $x2,     $y2 )     = @{ $pos{$callee} }{qw(x y)};
        push @svg_parts,
          sprintf( '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" '
              . 'stroke="#888" stroke-width="1.5" marker-end="url(#arrow)" />',
            $x1, $y1, $x2, $y2 );
    }

    for my $name (@names) {
        my ( $x, $y ) = @{ $pos{$name} }{qw(x y)};
        push @svg_parts,
          sprintf( '<circle cx="%.1f" cy="%.1f" r="6" fill="#4a90d9" />',
            $x, $y );
        push @svg_parts,
          sprintf(
            '<text x="%.1f" y="%.1f" font-family="sans-serif" font-size="11" '
              . 'text-anchor="middle">%s</text>',
            $x, $y - 10, svg_escape($name) );
    }

    print {$fh} svg_wrap( join( "\n", @svg_parts ), $size, $size );
    close $fh;
    return;
}

sub marker_def {
    return <<'SVG';
<defs>
  <marker id="arrow" markerWidth="10" markerHeight="10" refX="8" refY="3"
          orient="auto" markerUnits="strokeWidth">
    <path d="M0,0 L0,6 L9,3 z" fill="#888" />
  </marker>
</defs>
SVG
}

sub svg_wrap {
    my ( $body, $width, $height ) = @_;
    $width  //= 600;
    $height //= 400;
    return <<"SVG";
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height"
     viewBox="0 0 $width $height">
  <rect x="0" y="0" width="$width" height="$height" fill="white" />
$body
</svg>
SVG
}

sub svg_escape {
    my ($text) = @_;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    return $text;
}

sub print_summary {
    my ( $db_path, $report_path, $csv_path, $json_path, $svg_path ) = @_;
    print <<"SUMMARY";

[SUCCESS] Pipeline completed successfully!
--------------------------------------------------
1. CodeQuery GUI:
   codequery $db_path

2. Text overview report:
   $report_path

3. CSV relationship export:
   $csv_path

4. AI/JSON analysis report:
   $json_path

5. SVG call graph:
   $svg_path
--------------------------------------------------
SUMMARY
    return;
}

# ----------------------------------------------------------------------
# MAIN - Entrypoint
# ----------------------------------------------------------------------

# Requiring this file exposes the core API without starting the CLI.
main() unless caller;
