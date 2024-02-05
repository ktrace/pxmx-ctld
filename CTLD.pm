package PVE::Storage::LunCmd::CTLD;

# lightly based on code from LIO.pm
#
# additional changes:
# -----------------------------------------------------------------
# Copyright (c) 2019 Victor Kustov
# All Rights Reserved.
#
# This software is released under the terms of the
#
#            "GNU Affero General Public License"
#
# and may only be distributed and used under the terms of the
# mentioned license. You should have received a copy of the license
# along with this software product, if not you can download it from
# https://www.gnu.org/licenses/agpl-3.0.en.html
#
# Author: ktrace@yandex.ru
# -----------------------------------------------------------------

use strict;
use warnings;
use PVE::Tools qw(run_command);
use Data::Dumper;

sub get_base {
    return '/dev/zvol';
}


# config file location differs from distro to distro
my $CONFIG_FILE = '/etc/ctl.conf';  # FreeBSD 10+
my $BACKSTORE = 'storage';

my $SETTINGS = {};
my $SETTINGS_TIMESTAMP = 0;
my $SETTINGS_MAXAGE = 15; # in seconds

my @ssh_opts = ('-o', 'BatchMode=yes');
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my @scp_cmd = ('/usr/bin/scp', @ssh_opts);
my $id_rsa_path = '/etc/pve/priv/zfs';
my $targetcli = '/usr/sbin/ctladm';

#my $res = $execute_command->($scfg, 'scp', undef, $file, @params);
#my $res = $execute_command->($scfg, 'ssh', undef, 'cat', @params);
#my $res = $execute_command->($scfg, 'ssh', $timeout, $ietadm, @params);

my $execute_command = sub {
    my ($scfg, $exec, $timeout, $method, @params) = @_;

    my $msg = '';
    my $err = undef;
    my $target;
    my $cmd;
    my $res = ();

    $timeout = 10 if !$timeout;

    my $output = sub { $msg .= "$_[0]\n" };
    my $errfunc = sub { $err .= "$_[0]\n" };

    if ($exec eq 'scp') {
        $target = 'root@[' . $scfg->{portal} . ']';
        $cmd = [@scp_cmd, '-i', "$id_rsa_path/$scfg->{portal}_id_rsa", '--', $method, "$target:$params[0]"];
    } else {
        $target = 'root@' . $scfg->{portal};
        $cmd = [@ssh_cmd, '-i', "$id_rsa_path/$scfg->{portal}_id_rsa", $target, '--', $method, @params];
    }

    eval {
        run_command($cmd, outfunc => $output, errfunc => $errfunc, timeout => $timeout);
    };
    if ($@) {
        $res = {
            result => 0,
            msg => $err,
        }
    } else {
        $res = {
            result => 1,
            msg => $msg,
        }
    }

    return $res;
};


sub update_config {
    my ($scfg) = @_;
    my $file = "/tmp/config$$";
    my $content = '';
    my $tb = '     ';
    my $config = $SETTINGS;

    foreach my $tag (sort keys %{$config}) {
        $content .= $tag." ";
        foreach my $name (keys %{$config->{$tag}}) {
            $content .= $name." {\n";
            if ($tag !~ /^target/) {
                foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                $content .= "$tb$option $config->{$tag}->{$name}->{$option}\n";
                }
            } else {
                foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                    if ($option =~ /^lun$/) {
                        foreach my $lun_n (sort { $a <=> $b } keys %{$config->{$tag}->{$name}->{$option}}) {
                            $content .= "\n$tb$option $lun_n {\n";
                            my $lun = $config->{$tag}->{$name}->{$option}->{$lun_n};
                            foreach my $lun_opt (sort keys %{$lun}) {
                                $content .= "$tb $tb$ lun_opt $lun->{$lun_opt}\n";
                            }
                            $content .= "$tb}\n";
                        }
                    } else {
                        $content .= "$tb$option $config->{$tag}->{$name}->{$option}\n";
                    }
                }
            }
            $content .= "}\n";
        }

    }
    open(my $fh, '>', $file) or die "Could not open file '$file' $!";

    print $fh $content;
    close $fh;

    my @params = ($CONFIG_FILE);
    my $res = $execute_command->($scfg, 'scp', undef, $file, @params);
    unlink $file;
    die $res->{msg} unless $res->{result};
};



#checked
sub parse_options {
    my ($body, $config) = @_;

    my @chunks = split (/\n/, $body);
    foreach my $line (@chunks) {
        next if ($line !~ /(\S+)\s+(\S+)/);
        my ($dv, $option, $value) = split (/(\S+)\s+(\S+)/,$line);
        $config->{$option} = $value;
    }
};


my $parser = sub {
    my ($scfg) = @_;
    my $tpg = $scfg->{lio_tpg} || die "Target Portal Group not set, aborting!\n";
    my $tpg_tag;

    #my $base = get_base;


    my $res = $execute_command->($scfg, 'ssh', undef, 'cat', ($CONFIG_FILE));
    die "No configuration $CONFIG_FILE on $scfg->{portal}\n" unless $res->{result};

    my $config = $res->{msg};

    while ($config =~ /([\w\-\:\.]+)\s+([\w\-\.\:]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})/gs) {
        my ($tag, $name, $body) = ($1, $2, $3);
    if ($tag =~ /target/) {
        # need grep again
        while ( $body =~ /([\w\-\:\.]+)\s+([\w\-\.\:]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})/gs) {
                my ($lun, $lun_n, $lun_body) = ($1, $2, $3);
        # remove 3rd lever sections
        $lun_body =~ s/([\w\-\:\.]+)\s+([\w\-\.\:]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})//gs;
        $SETTINGS->{$tag}->{$name}->{$lun}->{$lun_n}  //= {};
        parse_options($lun_body, $SETTINGS->{$tag}->{$name}->{$lun}->{$lun_n});
        }
        #remove processed
        $body =~ s/([\w\-\:\.]+)\s+([\w\-\.\:]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})//gs;
        parse_options($body, $SETTINGS->{$tag}->{$name} //= {});
    } else {
        parse_options($body, $SETTINGS->{$tag}->{$name} //= {});
    }

    }
# <---- TODO. Check portal group
# No such portal groups;
# No such target;
# No such target in portal group;
};




# removes the given lu_name from the local list of luns
#
#  CHECK!!!CHECK!!!CHECK!!!
#
my $free_lu_name = sub {
    my ($lu_name) = @_;

    my $new = [];
    foreach my $lun (@{$SETTINGS->{target}->{luns}}) {
        if ($lun->{storage_object} ne "$BACKSTORE/$lu_name") {
        push @$new, $lun;
        }
    }

    $SETTINGS->{target}->{luns} = $new;
};

# locally registers a new lun
#
#  CHECK!!!CHECK!!!CHECK!!!
#
my $register_lun = sub {
    my ($scfg, $idx, $volname) = @_;

    my $conf = {
        index => $idx,
        storage_object => "$BACKSTORE/$volname",
        is_new => 1,
    };
    push @{$SETTINGS->{target}->{luns}}, $conf;

    return $conf;
};

# extracts the ZFS volume name from a device path
#
#  CHECK!!!CHECK!!!CHECK!!!
#
#my $extract_volname = sub {
#    my ($scfg, $lunpath) = @_;
#    my $volname = undef;
#
#    my $base = get_base;
#    if ($lunpath =~ /^$base\/$scfg->{pool}\/([\w\-]+)$/) {
#   $volname = $1;
#    }
#
#    return $volname;
#};

# retrieves the LUN index for a particular object
my $list_view = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $object = $params[0];

    my $file = "/tmp/debug-list-view.log";
    my $fh;
    open($fh, '>>', $file);
    $object =~ s/LUN//;
    print $fh Dumper(@params);

    close $fh;
    return $object;
};

# determines, if the given object exists on the portal
my $list_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;
    my $found = -1;

    my $object = $params[0];
    my $config = $SETTINGS;


    my $file = "/tmp/debug-list-lu.log";
    my $fh;
    open($fh, '>>', $file);
    print $fh "Object: $object\n";
#    print $fh Dumper($scfg,$config);

    foreach my $tag (keys %{$config}) {
        next if ($tag !~ /^target/);
        foreach my $name (keys %{$config->{$tag}}) {
            next if ($name !~ /^$scfg->{target}/);
            foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                next if ($option ne 'lun');
                foreach my $lun_n (sort keys %{$config->{$tag}->{$name}->{$option}}) {
                    if ($config->{$tag}->{$name}->{$option}->{$lun_n}->{path} =~ /$object/) {
 #                       print $fh Dumper($lun_n);
                        return "LUN$lun_n";
                    }
                }
            }
        }
    }

#    print $fh Dumper($found);
    close $fh;
    die "Not found";
};

# adds a new LUN to the target
my $create_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $device = $params[0];
    my $tpg = $scfg->{lio_tpg} || die "Target Portal Group not set, aborting!\n";

    my $config = $SETTINGS;

#    die "$params[0]: LUN already exists!" if ($list_lun->($scfg, $timeout, $method, @params));

# !!!!!!!!!!!!!!
    my $file = "/tmp/debug-create-lu.log";
    my $fh;
    open($fh, '>>', $file);
#    print $fh "scfg, config:\n";
#    print $fh Dumper($scfg,$config);
#    close $fh;
    my $candidate = 0;

    foreach my $tag (keys %{$config}) {
        next if ($tag !~ /^target/);
#        print $fh "- $tag\n";
        foreach my $name (keys %{$config->{$tag}}) {
            next if ($name !~ /^$scfg->{target}/);
#            print $fh "-- $name\n";
            foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
#                print $fh "--- $option\n";
                next if ($option !~ /^lun$/);
                foreach my $lun_n (sort { $a <=> $b } keys %{$config->{$tag}->{$name}->{$option}}) {
#                    print $fh "---- $lun_n, $candidate\n";
                    if ($lun_n == $candidate) {
#                        print $fh "----- Equal $lun_n == $candidate\n";
                        $candidate++;
                        next;
                    }
                    next if ($lun_n > $candidate);
                }
            }
        }
    }

    print $fh "candidate: $candidate\n";
    $config->{target}->{$scfg->{target}}->{lun}->{$candidate} //= {};
    $config->{target}->{$scfg->{target}}->{lun}->{$candidate}->{path} = $device;
    #$config->{target}->{$scfg->{target}}->{lun}->{$candidate}->{scsiname} = "$scfg->{target},lun,$candidate";
    #$config->{target}->{$scfg->{target}}->{lun}->{$candidate}->{ctld_name} = "$scfg->{target},lun,$candidate";
    print $fh Dumper($scfg,$config);
    close $fh;
    #die "I just DIE, see debug";
    my @cliparams = ('create', '-b block', "-o file=$device", "-l $candidate"); # VARS!!!!!!!!
    # my @cliparams = ('create', '-b block', "-o file=$device", "-o ctld_name=$scfg->{target},lun,$candidate -o scsiname=$scfg->{target},lun,$candidate"); # VARS!!!!!!!!
    my $res = $execute_command->($scfg, 'ssh', $timeout, $targetcli, @cliparams);
    die $res->{msg} if !$res->{result};

    die "Dangerous: try call lunmap with empry cLUN/pLUN" if ($candidate eq "");

    @cliparams = ('lunmap', '-p 3', "-l $candidate", "-L $candidate");
    # my @cliparams = ('create', '-b block', "-o file=$device", "-o ctld_name=$scfg->{target},lun,$candidate -o scsiname=$scfg->{target},lun,$candidate"); # VARS!!!!!!!!
    $res = $execute_command->($scfg, 'ssh', $timeout, $targetcli, @cliparams);
    die $res->{msg} if !$res->{result};

    update_config($scfg);

    return $res->{msg};
};

my $delete_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;
    my $res = {msg => undef};

    my $tpg = $scfg->{lio_tpg} || die "Target Portal Group not set, aborting!\n";

    my $to_kill = $params[0];
    $to_kill =~ s/LUN//;
    my $file = "/tmp/debug-delete-lu.log";
    open(my $fh, '>', $file);
    print $fh Dumper(@params);

    my $config = $SETTINGS;

    my $ok = 0;
    my $lun = undef;

    foreach my $tag (keys %{$config}) {
        next if ($tag !~ /^target/);
        foreach my $name (keys %{$config->{$tag}}) {
            next if ($name !~ /^$scfg->{target}/);
            foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                next if ($option !~ /^lun$/);
                foreach my $lun_n (sort keys %{$config->{$tag}->{$name}->{$option}}) {
                    if ($lun_n eq $to_kill) {
#                        print $fh "-- LUN$to_kill found in $config->{$tag}->{$name}->{$option}->{$lun_n}->{path}\n";
                        delete  $config->{$tag}->{$name}->{$option}->{$lun_n};
                        $ok = 1;
                    }
                    #$lun = $lun_n if ($config->{$tag}->{$name}->{$option}->{$lun_n}->{path} =~ /$path/);
                    #if ($config->{$tag}->{$name}->{$option}->{$lun_n}->{path} =~ /$path/) {
            #   print $fh "-- $params[0] not found in $config->{$tag}->{$name}->{$option}->{$lun_n}->{path}\n";
                    #} 
                }
            }
        }
    }

    die "LUN with num=$to_kill not found" if (not $ok);
#   print $fh Dumper($config);

    # step 1: delete the lun
    my @cliparams = ('remove', '-b block', "-l $to_kill" );
    print $fh Dumper($targetcli, @cliparams);
    $res = $execute_command->($scfg, 'ssh', $timeout, $targetcli, @cliparams);
    do {
        die $res->{msg};
    } unless $res->{result};

#   $free_lu_name->($volname);
    update_config($scfg);


    close $fh;
    return $res->{msg};
};

my $import_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    return $create_lun->($scfg, $timeout, $method, @params);
};

# needed for example when the underlying ZFS volume has been resized
my $modify_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;
    my $msg;

    $msg = $delete_lun->($scfg, $timeout, $method, @params);
    if ($msg) {
        $msg = $create_lun->($scfg, $timeout, $method, @params);
    }

    return $msg;
};

my $add_view = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    return '';
};

my %lun_cmd_map = (
    create_lu   =>  $create_lun,
    delete_lu   =>  $delete_lun,
    import_lu   =>  $import_lun,
    modify_lu   =>  $modify_lun,
    add_view    =>  $add_view,
    list_view   =>  $list_view,
    list_lu     =>  $list_lun,
);

sub run_lun_command {
    my ($scfg, $timeout, $method, @params) = @_;

    # fetch configuration from target if we haven't yet or if it is stale
    my $timediff = time - $SETTINGS_TIMESTAMP;
    if (!$SETTINGS || $timediff > $SETTINGS_MAXAGE) {
        $SETTINGS_TIMESTAMP = time;
        $parser->($scfg);
    }

    die "unknown command '$method'" unless exists $lun_cmd_map{$method};
    my $msg = $lun_cmd_map{$method}->($scfg, $timeout, $method, @params);

    return $msg;
}

1;
