#! /usr/bin/perl
#
# convert_omidyar_workspace.pl
#
# Given the path to a folder full of Omidyar Network workspace data (and
# several other important parameters; see usage below), processes the data
# in the folder to
# - convert reStructuredText files to Socialtext wiki markup
# - uploads images and other files as attachments to the appropriate
#   pages
# - tags converted pages with their source workspaces
#

use strict;
use warnings;

use FindBin;
use File::Spec::Functions;
use File::Basename;

# Add the local 'lib' directory to the module search path.
#
use lib catdir($FindBin::Bin, 'lib');


## Modules

use App::Options;
use URI::Escape;
use Socialtext::Resting;


## Constants

my $TMPDIR = $ENV{TEMP} || $ENV{TMP} || '/tmp';

my $TEMP_INPUT_PATHNAME     = catfile($TMPDIR, 'rst2socialtext-conversion-input.tmp');
my $TEMP_OUTPUT_PATHNAME    = catfile($TMPDIR, 'rst2socialtext-conversion-output.tmp');
my $TEMP_FILE_LOG_PATHNAME  = catfile($TMPDIR, 'rst2socialtext-conversion-file-log.tmp');

my $Command_Base;

use Carp;


## Subroutines

sub slurp {
#
# Opens and reads the entire file specified by the pathname parameter,
# then returns it (as a string or an array, depending on the context
# provided by the caller).
#
# If the optional 'binmode' parameter is true, binmode's the filehandle
# before reading.
#
    my $pathname = shift;
    my $binmode  = shift;

    open my $fh, '<', $pathname
        or croak "Can't open [$pathname] for reading -- $!\n";

    binmode $fh if $binmode;

    # If the caller wants an array, return all the lines in the
    # file as an array. Otherwise, return the whole file.
    #
    local $/ = (wantarray ? "\n" : undef);

    # Return the entire contents of the file, in whatever context the
    # caller wants.  The filehandle will be closed when it goes out of
    # scope.
    #
    return <$fh>;
}


sub r2s {
#
# Converts the specified string of reStructuredText to Socialtext
# markup, then returns the Socialtext markup as a string.
#
    my $r_text = shift;

    # Open the temporary input file and load it with the reStructuredText.
    #
    open my $in_fh, '>', $TEMP_INPUT_PATHNAME
        or die "Unable to open file $TEMP_INPUT_PATHNAME -- $!\n";

    print {$in_fh} $r_text;

    close $in_fh;

    # Build the command line from the base command (see above) and the
    # input and output pathnames.
    #
    my $cmdline = $Command_Base . " $TEMP_INPUT_PATHNAME >$TEMP_OUTPUT_PATHNAME";

    # Generate the output using the prest command. This also
    # generates the list of attachments in a separate temp file.
    #
    system($cmdline);

    my $s_text = slurp($TEMP_OUTPUT_PATHNAME);

    # Clean up.
    #
    unlink $TEMP_INPUT_PATHNAME;
    unlink $TEMP_OUTPUT_PATHNAME;

    return $s_text;
}



sub rfile2sfiles {
    my $r_filepath = shift;
    my $s_dest_path = shift;

    # Open the source file and read it into a string.
    #
    my $r_text = slurp($r_filepath);

    # Strip the header from the start of the file.
    #
    $r_text =~ s{
        \A                              # very beginning of string
        \s*                             # whitespace before the header 
        ^Group:             \s  .*? \n  # header line
        ^Workspace:         \s  .*? \n  # header line
        ^Short[ ]name:      \s  .*? \n  # header line
        ^Created:           \s  .*? \n  # header line
        ^Final[ ]Edit:      \s  .*? \n  # header line
        ^Final[ ]Author:    \s  .*? \n  # header line
        ^Feedback[ ]Score:  \s  .*? \n  # header line
        \s*                             # whitespace after the header
    }{}ixms;

    # Correct some common indentation problems. This converts any
    # indentation of 1 through 4 spaces, or a single tab, into a
    # three-space indent.
    #
    # XXX: This doesn't fix all of the indentation problems.
    # Some indentation can still cause trouble for the prest parser.
    #
    $r_text =~ s/^([ ]{1,4}|\t)([^ \t])/   $2/mg;
    
    # Convert any on-include directives to Socialtext {include}
    # directives.  This is much simpler than implementing an actual
    # on-include reST directive, then inserting the appropriate DOM
    # objects, etc.
    # 
    $r_text =~ s/
        ^               # start of line
        ([ \t]*)        # zero or more spaces or tabs, captured so it can be preserved
        \.\.            # two periods, indicating the start of a directive
        [ \t]+          # one or more spaces or tabs             
        on-include      # directive name
        [ \t]*          # zero or more spaces or tabs 
        ::              # two colons after the directive name
        [ \t]*          # zero or more spaces or tabs 
        (.+)            # name of the page to include
        $               # end of line
        /$1\{include [$2]\}/mgx;

    # Unindent any indented csv-table directives.
    # 
    # XXX: There are probably other directives with this problem.
    # It's worth doing an exhaustive search.
    #
    $r_text =~ s/^\s+\.\. csv-table/\n.. csv-table/mg;

    # Convert the reST to Socialtext markup.
    #
    my $s_text = r2s($r_text);

    # Derive the output file name and path.
    #
    my ($s_filebase, undef, $s_fileext) = fileparse($r_filepath, '.txt');
    my $s_filename = $s_filebase . $s_fileext . '.st';
    my $s_filepath = catdir($s_dest_path, $s_filename);

    # Write the converted text to the output file.
    #
    my $s_fh;
    open $s_fh, '>', $s_filepath
        or die "Unable to open [$s_filepath] for output -- $!\n";

    print {$s_fh} $s_text;

    close $s_fh;

    # Return the output filename, so it can be used in additional
    # processing (like uploading).
    #
    return $s_filepath;
}


## Main

# Gather up the command-line arguments.
#
# XXX: This has grown out of control. Replace it with a Getopt call
# and a proper usage message.
#
my $src_path            = shift;
my $dest_path           = shift;
my $source_group_name   = shift;  # Ex: hu-internal
my $dest_workspace_name = shift;  # Ex: humanityunited
my $source_server       = shift || 'https://www.omidyar.net/';
my $dest_server         = shift || 'http://www.socialtext.net/';

die 'Please provide all arguments:

    src_path            # required
    dest_path           # required

    source_group_name   # Ex: hu-internal
    dest_workspace_name # Ex: humanityunited

    source_server       # defaults to https://www.omidyar.net/
    dest_server         # defaults to http://www.socialtext.net/

'
    unless ($src_path           and $dest_path
        and $source_group_name  and $dest_workspace_name
        and $source_server      and $dest_server
    );

# Build the base prest command line from the parameters provided by the
# user.
# 
$Command_Base = ''
    . './bin/run-prest'
    . ' -w socialtext'
    . ' -D report=3'
    . qq( -W source-group-name='$source_group_name')
    . qq( -W source-server='$source_server')
    . qq( -W file-log='$TEMP_FILE_LOG_PATHNAME')
;

print <<END_TEXT;

Running with these options:

    src_path            [$src_path]
    dest_path           [$dest_path]

    source_group_name   [$source_group_name]
    dest_workspace_name [$dest_workspace_name]

    source_server       [$source_server]
    dest_server         [$dest_server]

END_TEXT

print "Press Return to continue, or Ctrl+C to abort: "; <>;


# Prepare to upload files to the target workspace
#
# XXX: Pull these from a config file, or provide command-line options
# for them.
#
my $Rester = Socialtext::Resting->new(
    username => $App::options{username},
    password => $App::options{password},
    server   => $dest_server,
    'accept' => 'text/x.socialtext-wiki'
);

$Rester->workspace($dest_workspace_name);

my $File_Path = catdir($src_path, 'files');

# Open the workspace subdirectory of the source
#
my $ws_path = catdir($src_path, 'workspaces');
my $ws_dh;
opendir $ws_dh, $ws_path
    or die "Unable to open $ws_path";

# Get the text files from the workspace directory. This part of the archive
# directory structure is flat, so there's no need to walk a directory tree.
# This also avoids having to skip '.' and '..' in the loop below.
#
my @ws_files = grep { /\.txt$/i } readdir($ws_dh);

closedir $ws_dh;

# Process each file in the list.
#
for my $ws_file (@ws_files) {

    print <<END_TEXT;
==========================================================================
Processing [$ws_file]
END_TEXT

    # Convert the file from Omidyar reST to Socialtext markup.
    #
    my $dest_pathname = rfile2sfiles(catfile($ws_path, $ws_file), $dest_path);

    # Upload the converted page to the server, and provide a list of the files
    # to be attached to the page as well so they can be uploaded, too.
    #
    upload_page($dest_pathname, $TEMP_FILE_LOG_PATHNAME);
}


sub upload_page {
#
# Uploads the specified file to the target workspace. If there are attachments
# listed in the specified file log, uploads the attachments as well.
#
    my $dest_pathname       = shift;
    my $file_log_pathname   = shift;

    my $content = slurp($dest_pathname);

    my $page_name = basename($dest_pathname);

    # Get rid of the group name prefix and the trailing extensions.
    #
    $page_name =~ s/^\Q$source_group_name\E-//;
    $page_name =~ s/\.txt\.st$//;

    print "Uploading page [$page_name] using contents from [$dest_pathname]\n";

    # Upload the page.
    #
    $Rester->put_page($page_name, $content);

    # Tag the page with the source group name, to make it easier to find
    # in the new workspace.
    #
    $Rester->put_pagetag($page_name, $source_group_name);

    # Don't bother to continue if there's not a list of files to
    # upload.
    #
    return unless -s $file_log_pathname;

    # Attach the files to the page.
    #
    print "Uploading attachments to page [$page_name]\n";

    my (@uris) = slurp($file_log_pathname);

    URI:
    for my $uri (@uris) {

        print "Processing URI [$uri]\n";

        # The relative filename is everything after the
        # /get/ portion of the uri.
        #
        # XXX: Make sure this is consistent in the source files.
        #
        my ($relative_filename) = ($uri =~ m{/get/(.+)$});

        # Get rid of all the %20's and their friends.
        #
        $relative_filename = uri_unescape($relative_filename);

        # Figure out where the attachment source file should be.
        #
        my $filepath = catfile($File_Path, $relative_filename);

        if (! -e $filepath) {
            print "WARNING: Skipping [$filepath] -- file does not exist.\n";
            next URI;
        }

        my $filename = basename($filepath);

        # Some of the URIs are just pathnames, without specified
        # files. This catches them, so no attempt will be made to
        # upload blank filenames.
        #
        if (! $filename) {
            print "WARNING: Unable to upload file based on URI [$uri] -- no filename.\n";
            next URI;
        }

        print "- Uploading [$filepath] as attachment [$filename] based on URI [$uri]\n";

        my $attachment_content = slurp($filepath, 'binmode');
        
        my $attachment_id = $filename;

        my $mime_type = 'application/octet-stream';

        # Add the attachment to the page.
        # 
        $Rester->post_attachment(
            $page_name, 
            $attachment_id, 
            $attachment_content, 
            $mime_type
        );
    } # end for URI
}

# end convert_omidyar_workspace.pl
