#!/usr/bin/perl
# Tool for checking status of multiple sites
# http://mattharris.org

use strict;
use warnings;
use Getopt::Long;
use LWP::UserAgent;
use IPC::Open3;
use HTTP::Status 'status_message';
use Cwd;
use Sys::Hostname;
use Socket;
use Carp;

my $panel;
my $format = "%-50s %-50s \n";

if ( -f '/usr/local/cpanel/version' ) {
    $panel = 'cpanel';
}
if ( -d '/usr/local/psa' ) {
    $panel = 'psa';
}

my $timeout;
my @ips = getips();
get_options();

# define options and determine path
sub get_options {
    my ( $all, $user, $reseller, $domain, $verbose, $show, $help, $sleep );
    GetOptions(
        'all|a'        => \$all,
        'user|u=s'     => \$user,
        'reseller|r=s' => \$reseller,
        'domain|d=s'   => \$domain,
        'verbose|v'    => \$verbose,
        'help|h'       => \$help,
        'timeout|t=i'  => \$timeout,
        'sleep|s=i'    => \$sleep,
    );
    my $lavg        = get_load_average();
    my $cores       = get_cores();
    my $sleep_count = 0;
    if ( !$sleep ) { $sleep = 5; }
    while ( $lavg > $cores ) {
        if ( $sleep_count > 2 ) {
            print
              "Perhaps, you should fix the load before checking the sites?\n";
            exit;
        }
        print "Load Average: $lavg, sleeping for $sleep seconds\n";
        sleep $sleep;
        $sleep_count++;
    }
    if ( !$timeout ) { $timeout = '5'; }
    else             { $timeout =~ s/\D//g; }
    if ($verbose) {
        $show = 1;
    }
    if ($all) {
        if ( $panel eq 'cpanel' ) {
            Cpanel::Checksites::all($show);
        }
        elsif ( $panel eq 'psa' ) {
            Plesk::Checksites::all($show);
        }
        exit;
    }
    if ($user) {
        Cpanel::Checksites::user( $show, $user );
        exit;
    }
    if ($reseller) {
        Cpanel::Checksites::reseller( $show, $reseller );
        exit;
    }
    if ($domain) {
        domain( $show, $domain );
        exit;
    }
    if ( $help || !defined $ARGV[0] ) {
        help();
        exit;
    }
}

sub domain {
    my ( $show, $domain ) = @_;
    printf $format, 'DOMAIN', 'ISSUE/STATUS';
    checksite( $show, $domain );
    return;
}

sub help {
    my $usage = <<'EOF';
     
  checksites [OPTIONS] [INPUT]
     
     Options:
        --all, -a          Check status of all the domains on the server
        --domain, -d       Check status of one domain
        --user, -u         Check status of all the domains owned by user
        --reseller, -r     Check status of all domains under a reseller
        --verbose, -v      Show websites that are working
        --timeout, -t      Specifies a timeout for requests, defaults to 5 seconds.
        --sleep, -s        Set sleep time for load average check, defaults to 10 seconds.
        --help,-h          Show this page

EOF
    my $error = print $usage;
    return;
}

# get ips on the server
sub getips {
    my ( $writer, $reader, $error );
    open3( $writer, $reader, $error, '/sbin/ifconfig' );
    my @ifconfig = <$reader>;
    foreach (@ifconfig) {
        if ( $_ =~ /inet\saddr:(\S+)/xsm && $_ !~ /127[.]0[.]0[.]1/xsm ) {
            push @ips, $1;
        }
    }
    return @ips;
}

# perform dns resolution on a domain
sub dnsres {
    my $domain  = shift;
    my $ba      = inet_aton($domain);
    my $address = 'IP not configured';
    if ($ba) {
        $address = inet_ntoa($ba);
    }
    return $address;
}

# check the sites dns and status code
sub checksite {
    my ( $show, $domain ) = @_;
    my $count = 0;
    my $found = 0;
    my $ip;
    $ip = dnsres($domain);
    if ( $ip =~ /IP not configured/sm ) {
        printf $format, "[!] http://$domain", 'Non-existent or DNS Error';
    }
    else {
        foreach (@ips) {
            if ( $ip eq $_ ) {
                $count++;
            }
        }
        if ( $count < 1 ) {
            printf $format, "[!] http://$domain", "Points to $ip";
            $found++;
        }
        if ( $found < 1 ) {
            my $ua = LWP::UserAgent->new;
            $ua->agent('HG Site Checker');
            $ua->timeout($timeout) or croak 'TIMEOUT';
            my $response = $ua->get("http://$domain");
            my $check    = content_check($domain);
            if ( $response->is_success ) {
                $response = $response->{_rc};
                if ($show) {
                    if ( $response =~ /^2/xsm ) {
                        if ($check) {
                            printf $format, "[!] http://$domain", "$check";
                        }
                        else {
                            my $rc = $response;
                            $response = status_message($response);
                            printf $format, "[+] http://$domain",
                              "$rc $response";
                        }
                    }
                }
                else {
                    if ( $response !~ /^2/xsm ) {
                        my $rc = $response;
                        $response = status_message($response);
                        printf $format, "[!] http://$domain", "$rc $response";
                    }
                }
            }
            else {
                $response = $response->status_line;
                printf $format, "[!] http://$domain", "$response";
            }
        }
    }
    return;
}

# Check content for common issues
sub content_check {
    my $domain = shift;
    my $ua     = LWP::UserAgent->new;
    $ua->timeout($timeout);
    my $req = HTTP::Request->new( GET => "http://$domain/" );
    my $res = $ua->request($req);
    if ( $res->content() =~
        m/(defaultwebpage[.]cgi|searchdiscovered[.]com)/xism )
    {
        return 'Cpanel Default Page';
    }
    elsif ( $res->content() =~ m/database\serror/xism ) {
        return 'Database Error';
    }
    elsif ( $res->content() =~ m/account\ssuspended/xism ) {
        return 'Suspended Account';
    }
    elsif ( $res->content() =~ m/<title>Index\sof\s(.*)<\/title>/xsm ) {
        return "Directory Index for $1";
    }
    elsif ( $res->content() =~ m/\/var\/lib\/mysql\/mysql.sock/xsm ) {
        return 'MySQL Error';
    }
    elsif ( $res->content() =~ m/<title>(Domain\sDefault\spage|Default\sParallels\sPlesk\sPanel\sPage)<\/title>/xsm ) {
        return 'Plesk default page';
    }
    elsif ( $res->content() =~
m/(hacked|haxor|c3284d|Web Shell|WebShell|iskorpitx|shell_atildi|md5_pass|wp_add_filter|shellbot|c99\s?shell|injektor|N3tsh|Fx29sh|r57\s?shell|SyRiAn Sh3ll|FilesMan|CGI-Telnet|MulCiShell|LINUX Shell|Team Crimes Linux|Zone-H|Err0R|hackteach|JAGo-Dz|Cpanel Cracker|milw0rm|PHP DOS|phptools|Manix|exploit-db|b0VIM|phpshell|w4ck1ng-shell|ITSecTeam|CraCkeR|SarBoT|SA3D|HaCk3D|SUKSES|Fx29Shell|SyRiAn|Sh3ll|SnIpEr_SA|Symlink User Bypass|greetz|KeNiHaCk|1923Turk|strrev..edoced_46esab|sEc4EvEr|Mr.aFiR|Hacked By|auth_pass|shell_exec|Terminator|WSO_VERSION|ignore_user_abort|jquerye\.com|PHP_OS)/ixsm
      )
    {
        return 'Possibly Hacked -> Manually Confirm';
    }
}

sub get_load_average {
    open my $fh, '<', "/proc/loadavg" or croak "Unable to get server load";
    my $load_avg = <$fh>;
    close $fh;
    my ($one_min_avg) = split /\s/, $load_avg;
    return $one_min_avg;
}

sub get_cores {
    open my $fh, '<', "/proc/cpuinfo" or croak "Unable to get cpuinfo";
    my $proc_count;
    while (<$fh>) {
        $proc_count++ if $_ =~ /^processor/;
    }
    close $fh;
    return $proc_count;
}

package Cpanel::Checksites;
use Carp;

# get domains for a user
sub getdomains {
    my $user = shift;
    my $file = "/var/cpanel/userdata/$user/main";
    my (@domains);
    open my $fh, '<', $file or croak "[!] File does not exist: $file";
    while (<$fh>) {

        # pull addon domains
        if ( $_ =~ /(\S+):\s/xsm && $_ !~ /_/xsm ) {
            push @domains, $1;
        }

        # pull main domain
        if ( $_ =~ /main_domain:\s(\S+)/xsm ) {
            push @domains, $1;
        }

        # pull parked domains
        if ( $_ =~ /-\s(\S+)/xsm ) {
            push @domains, $1;
        }
        if ( $_ =~ /sub_domains:/xsm ) {
            last;
        }
    }
    my $error = close $fh;
    return @domains;
}

sub all {
    my $show = shift;
    opendir my $dh, '/var/cpanel/userdata/';
    my @users = readdir $dh;
    closedir $dh;
    my ( @newdomains, @domains );
    foreach my $acct (@users) {
        next if ( $acct eq q{.} or $acct eq q{..} or $acct eq 'nobody' );
        @newdomains = getdomains($acct);
        push @domains, @newdomains;
    }
    printf $format, 'DOMAIN', 'ISSUE/STATUS';
    foreach my $domain (@domains) {
        main::checksite( $show, $domain );
    }
    return;
}

sub user {
    my ( $show, $user ) = @_;
    my @domains = getdomains($user);
    printf $format, 'DOMAIN', 'ISSUE/STATUS';
    foreach my $domain (@domains) {
        main::checksite( $show, $domain );
    }
    return;
}

sub reseller {
    my ( $show, $reseller ) = @_;
    my ( @accounts, @domains, @newdomains );
    my $file = '/etc/trueuserowners';
    open my $fh, '<', $file or croak "File does not exist: $file";
    while (<$fh>) {
        if ( $_ =~ /(\S+):\s$reseller$/smx ) {
            push @accounts, $1;
        }
    }
    my $error = close $fh;
    foreach my $acct (@accounts) {
        @newdomains = getdomains($acct);
        push @domains, @newdomains;
    }
    printf $format, 'DOMAIN', 'ISSUE/STATUS';
    foreach my $domain (@domains) {
        main::checksite( $show, $domain );
    }
    return;
}

package Plesk::Checksites;
use DBI;
use Carp;

sub all {
    my $show    = shift;
    my $domains = getdomains();
    printf $format, 'DOMAIN', 'ISSUE/STATUS';
    foreach my $domain ( @{$domains} ) {
        main::checksite( $show, @{$domain} );
    }
    return;
}

sub getdomains {
    my $username = 'admin';
    chomp( my $password = get_pass() );
    my $dbh = DBI->connect( 'DBI:mysql:database=psa;host=localhost',
        $username, $password )
      or croak 'Cannot connect to database!';
    my $query = $dbh->prepare('SELECT domains.name FROM domains;');
    $query->execute() or croak 'Database error!';
    my $domains = $query->fetchall_arrayref;
    return $domains;
}

sub get_pass {
    open my $fh, '<', '/etc/psa/.psa.shadow'
      or croak 'Cannot open plesk password';
    my $password = <$fh>;
    close $fh or croak 'Cannot close file!';
    chomp $password;
    return $password;
}
