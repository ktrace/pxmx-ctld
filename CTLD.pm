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

#  CTL has two LUN's: pLUN and cLUN. Here cLUN - inner data 



use strict;
use warnings;
use PVE::Tools qw(run_command);
use Data::Dumper;
use UUID 'uuid';

sub get_base {
    return '/dev/zvol';
}


# config file location differs from distro to distro
my $CONFIG_FILE = '/etc/ctl.conf';    # FreeBSD 10+
my $BACKSTORE = 'storage';

my $SETTINGS = {};
my $SETTINGS_TIMESTAMP = 0;
my $SETTINGS_MAXAGE = 15; # in seconds

my @ssh_opts = ('-o', 'BatchMode=yes');
my @ssh_cmd = ('/usr/bin/ssh', @ssh_opts);
my @scp_cmd = ('/usr/bin/scp', @ssh_opts);
my $id_rsa_path = '/etc/pve/priv/zfs';
my $targetcli = '/usr/sbin/ctladm';

my $o_vendor = "FreeBSD";
my $o_product = "iSCSI Disk";
my $o_revision = "1961";
my $o_insec = "on";
my $o_rpm = "1";

my $execute_command = sub {
    my ($scfg, $exec, $timeout, $method, @params) = @_;

    my $file = "/tmp/debug-execute_command.log";
    open(my $fh, '>>', $file);

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

    print $fh Dumper($cmd,$res);
    close $fh;

    return $res;
};


sub update_config {
    my ($scfg) = @_;
    my $file = "/tmp/config$$";
    my $content = '';
    my $tb = '     ';
    my $config = $SETTINGS;

    foreach my $tag (sort keys %{$config}) {
        foreach my $name (keys %{$config->{$tag}}) {
            $content .= $tag." \"$name\" {\n";
            if ($tag !~ /^target/) {
                foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                    if ($option =~ /^option$/) {
                        foreach my $opt (sort keys %{$config->{$tag}->{$name}->{$option}}) {
                            $content .= "$tb$option \"$opt\" \"$config->{$tag}->{$name}->{$option}->{$opt}\"\n";
                        }
                    } else {
                        $content .= "$tb$option \"$config->{$tag}->{$name}->{$option}\"\n";
                    }
                }
            } else {
                foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                    if (($option =~ /^lun$/)||($option =~ /^portal-group$/)) {
                        foreach my $lun_n (sort keys %{$config->{$tag}->{$name}->{$option}}) {
                            # parse lun 3 parameters
                            my $lun = $config->{$tag}->{$name}->{$option}->{$lun_n};
                            $content .= "$tb$option \"$lun_n\" \"$lun\"\n";
                        }
                    } else {
                        $content .= "$tb$option \"$config->{$tag}->{$name}->{$option}\"\n";
                    }
                }
            }
            $content .= "}\n\n";
        }

    }
    open(my $fh, '>', $file) or die "Could not open file '$file' $!";

    print $fh $content;
    close $fh;
#    print Dumper($content); # TODO: kill

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
        if ($line =~ /(\S+)\s+\"(.+)\"\s+\"(.+)\"/) {
            my ($dv, $option, $value, $value1) = split (/(\S+)\s+\"(.+)\"\s+\"(.+)\"/,$line);
            $config->{$option}->{$value} = $value1;
        } else {
            my ($dv, $option, $value) = split (/(\S+)\s+\"(.+)\"/,$line);
            $config->{$option} = $value;
        }
    }
};

sub get_plun {
    my ($scfg,$lu_name) = @_;
    my @cliparams = ('devlist', '-v');
    my $res = $execute_command->($scfg, 'ssh', undef, $targetcli, @cliparams);
    die $res->{msg} if !$res->{result};

    my $file = "/tmp/debug-get_plun.log";
    open(my $fh, '>>', $file);
    print $fh "dev $lu_name\n";
#    close $fh;

    while ($res->{msg} =~ /((\d+)\s+block\s+.*$(?:\s+\w+=.+$)+)/gm) {
#    while ($res->{msg} =~ /(?=((\d+)\s+block\s+.+?)(?:\d+\s+block|\z))/gs) {
        my ($block, $index) = ($1, $2);
        print $fh "Compare: $block and $lu_name\n";
        # validation? 
        return $index if ($block =~ /$lu_name/);
    }
    return -1;
}

sub clunlist {
# return cLUN list
# map cLUN -> name
    my ($scfg) = @_;
    my @cliparams = ('portlist', '-v');
    my $res = $execute_command->($scfg, 'ssh', undef, $targetcli, @cliparams);
    die $res->{msg} if !$res->{result};
    my $lunmap //= {};
    while ($res->{msg} =~ /(?:Target: $scfg->{target})((?:\s+LUN\s\d+:\s\d+)*)(?:\s+\w+=[\w\.:-]+)*/gm) {
        my $list = $1;
#        print ":: cycle :: $1"; # TODO: kill
        while ($list =~ /(?:\s+LUN\s(\d+):\s(\d+))/gs) {
#            print ":::: cycle :::: $1 $2"; #TODO: kill
            $lunmap->{$1} = $2;
        }
    }
#    print Dumper($lunmap);
    return $lunmap;
}

sub get_port {
# get target ID
    my ($scfg) = @_;
    my $result = undef;
    my $tgt = $scfg->{target};
    my @cliparams = ('portlist', '-l');
    my $res = $execute_command->($scfg, 'ssh', undef, $targetcli, @cliparams);
    die $res->{msg} if !$res->{result};
    $res->{msg} =~ /^(\d+)\s+(\w+)\s+(\w+)\s+(\w+)\s+(\d+)\s+(\d+)\s+($tgt)(.*)$/gm;
    return $1 if ($1);
    return -1;
#die "No port found for $tgt";
}

my $parser = sub {
    my ($scfg) = @_;
    my $tpg = $scfg->{lio_tpg} || die "Target Portal Group not set, aborting!\n";
    my $tpg_tag;

#    print "Parser::\n"; # TODO: kill
    my $res = $execute_command->($scfg, 'ssh', undef, 'cat', ($CONFIG_FILE));
    die "No configuration $CONFIG_FILE on $scfg->{portal}\n" unless $res->{result};

    my $config = $res->{msg};
#    print Dumper($config); # TODO: kill

    while ($config =~ /([\w\-\:\.]+)\s+([\w\-\.\:\"]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})/gs) {
        my ($tag, $name, $body) = ($1, $2, $3);
            $name =~ s/\"//g;
            if ($tag =~ /target/) {
                # need grep again
                while ( $body =~ /([\w\-\:\.]+)\s+([\w\-\.\:\"]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})/gs) {
                    my ($lun, $lun_n, $lun_body) = ($1, $2, $3);
                    # remove 3rd lever sections
                    $lun_body =~ s/([\w\-\:\.]+)\s+([\w\-\.\:]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})//gs;
                    $SETTINGS->{$tag}->{$name}->{$lun}->{$lun_n}  //= {};
                    parse_options($lun_body, $SETTINGS->{$tag}->{$name}->{$lun}->{$lun_n});
                }
                #remove processed
                $body =~ s/([\w\-\:\.]+)\s+([\w\-\.\:\"]+)\s+(\{(?>(?>[^{}]+)|(?3))*\})//gs;
                parse_options($body, $SETTINGS->{$tag}->{$name} //= {});
            } else {
                parse_options($body, $SETTINGS->{$tag}->{$name} //= {});
            }

    }
# <---- TODO. Check portal group``
# No such portal groups;
# No such target;
# No such target in portal group;
#
# print Dumper($SETTINGS);

};



# retrieves the LUN index for a particular object
my $list_view = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my $object = $params[0];
    $object =~ s/LUN//;

    my $file = "/tmp/debug-list-view.log";
    open(my $fh, '>>', $file);
    print $fh Dumper(@params);
    close $fh;

return $object;
};

# determines, if the given object exists on the portal
my $list_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;
    my $found = undef;

    #my $object = $params[0]; # full path to zvol
    my ($path,$device) = $params[0] =~ /(.*\/)([^\/]+)$/;

    my $config = $SETTINGS;


    my $file = "/tmp/debug-list-lu.log";
    open(my $fh, '>>', $file);
    print $fh "Object: $path,$device\n";
#    print $fh Dumper($scfg,$config);

    foreach my $tag (keys %{$config}) {
        next if ($tag !~ /^target/);
        foreach my $name (keys %{$config->{$tag}}) {
            next if ($name !~ /^$scfg->{target}/);
            foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                next if ($option ne 'lun');
                foreach my $lun_n (sort keys %{$config->{$tag}->{$name}->{$option}}) {
                    if ($device =~ /$config->{$tag}->{$name}->{$option}->{$lun_n}/) {
                       $found = $lun_n;
		       #return "$lun_n";
                    }
                }
            }
        }
    }

    print $fh Dumper($found,$device);
    close $fh;
    return $device if defined $found;
    die "Not found";
};

# adds a new LUN to the target
my $create_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;

    my ($path,$device) = $params[0] =~ /(.*\/)([^\/]+)$/;
    my $tpg = $scfg->{lio_tpg} || die "Target Portal Group not set, aborting!\n";

    my $port = get_port($scfg);
# TODO: if -1 then addport()
    my $config = $SETTINGS;

#    die "$params[0]: LUN already exists!" if ($list_lun->($scfg, $timeout, $method, @params));

# !!!!!!!!!!!!!!
    my $file = "/tmp/debug-create-lu.log";
    open(my $fh, '>>', $file);
#    print $fh "scfg, config:\n";
#    print $fh Dumper($scfg,$config);
#    close $fh;
    my $candidate = 0;

    if ($port == -1) {
        $config->{target}->{$scfg->{target}}->{'portal-group'}->{pg1} = 'no-authentication';
        $config->{target}->{$scfg->{target}}->{alias} = 'pg1';
    }

    foreach my $tag (keys %{$config}) {
        next if ($tag !~ /^target/);
#        print "- $tag\n"; # TODO: off
        foreach my $name (keys %{$config->{$tag}}) {
            next if ($name !~ /^$scfg->{target}/);
#            print "-- $name\n"; # TODO: off
            foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
#                print "--- $option\n"; # TODO: off
                next if ($option !~ /^lun$/);
                foreach my $lun_n (sort keys %{$config->{$tag}->{$name}->{$option}}) {
#                    print "---- $lun_n, $candidate\n"; # TODO: off
                    if ($lun_n == $candidate) {
#                        print "----- Equal $lun_n == $candidate\n"; # TODO: off
                        $candidate++;
                        next;
                    }
                    next if ($lun_n > $candidate);
                }
            }
        }
    }

    my $hash = uuid();
    $hash =~ s/-//g;

    print $fh "candidate: $candidate\n"; # TODO: off
    # $config->{target}->{$scfg->{target}}->{lun}->{$candidate} //= {};
    $config->{target}->{$scfg->{target}}->{lun}->{$candidate} = $device;
    #$config->{target}->{$scfg->{target}}->{lun}->{$candidate}->{scsiname} = "$scfg->{target},lun,$candidate";
    #$config->{target}->{$scfg->{target}}->{lun}->{$candidate}->{ctld_name} = "$scfg->{target},lun,$candidate";
    $config->{lun}->{$device}->{serial} = lc(substr($hash,-14,12));
    $config->{lun}->{$device}->{"ctl-lun"} = "$candidate";
    $config->{lun}->{$device}->{path} = "$path$device";
    $config->{lun}->{$device}->{blocksize} = "4096";
    $config->{lun}->{$device}->{option}->{naa} = "0x6589cfc000000".lc(substr($hash,4,19));
    $config->{lun}->{$device}->{option}->{vendor} = $o_vendor;
    $config->{lun}->{$device}->{option}->{revision} = $o_revision;
    $config->{lun}->{$device}->{option}->{rpm} = $o_rpm;
    $config->{lun}->{$device}->{option}->{product} = $o_product;
    $config->{lun}->{$device}->{option}->{insecure_tpc} = $o_insec;

    print $fh "Result, will write:\n";
    print $fh Dumper($scfg,$config);
    close $fh;
    #die "I just DIE, see debug";
    my @cliparams = ('create', '-b block',
        "-S $config->{lun}->{$device}->{serial}",
        "-B 4096",
        "-o file=$path$device",
        "-o product='$config->{lun}->{$device}->{option}->{product}'",
        "-o vendor=$config->{lun}->{$device}->{option}->{vendor}",
        "-o revision=$config->{lun}->{$device}->{option}->{revision}",
        "-o insecure_tpc=$config->{lun}->{$device}->{option}->{insecure_tpc}",
        "-o naa=$config->{lun}->{$device}->{option}->{naa}",
        "-o rpm=$config->{lun}->{$device}->{option}->{rpm}",
        "-d '$config->{lun}->{$device}->{option}->{product}\t$config->{lun}->{$device}->{serial}\t'"); #,
#        "-l $candidate"); # VARS!!!!!!!!
    my $res = $execute_command->($scfg, 'ssh', $timeout, $targetcli, @cliparams);
    die $res->{msg} if !$res->{result};

    my $pLUN = get_plun($scfg,$device);
    die "Can't get pLUN" if ($pLUN < 0);
    # map lun 
    @cliparams = ('lunmap', '-p',$port, '-l', $candidate, '-L', $pLUN);
    $res = $execute_command->($scfg, 'ssh', 10, $targetcli, @cliparams);
#    die $res->{msg} if !$res->{result};
    update_config($scfg);
    return $res->{msg};
};

my $delete_lun = sub {
    my ($scfg, $timeout, $method, @params) = @_;
    my $res = {msg => undef};

    # validation
    my $tpg = $scfg->{lio_tpg} || die "Target Portal Group not set, aborting!\n";

    my $to_kill = $params[0]; # cLUN here

# TODO: remove it
    my $file = "/tmp/debug-delete-lu.log";
    open(my $fh, '>', $file);
    print $fh "LUN for delete: $to_kill",Dumper(@params);

    my $config = $SETTINGS;

    my $found = -1;
    my $lun = undef;
    
    my $port = get_port($scfg);
#    my $clunlist = clunlist();
    foreach my $tag (keys %{$config}) {
        next if ($tag !~ /^target/);
        foreach my $name (keys %{$config->{$tag}}) {
            next if ($name !~ /^$scfg->{target}/);
            foreach my $option (sort keys %{$config->{$tag}->{$name}}) {
                next if ($option !~ /^lun$/);
                foreach my $lun_n (sort keys %{$config->{$tag}->{$name}->{$option}}) {
	            print $fh "-- $lun_n , $to_kill , $config->{$tag}->{$name}->{$option}->{$lun_n}\n";
                    if ($config->{$tag}->{$name}->{$option}->{$lun_n} eq $to_kill) {
                        print $fh "-- $to_kill found in $config->{$tag}->{$name}->{$option}->{$lun_n}\n";
                        $found = $lun_n;
                        delete  $config->{$tag}->{$name}->{$option}->{$lun_n};
                        delete  $config->{lun}->{$to_kill};
                    }
                }
            }
        }
    }


    print $fh "LUN with num=$to_kill not found\n" if ($found < 0);
    print $fh Dumper($config);

    my $pLUN=get_plun($scfg,$to_kill);

    # step 1: unmap clun
    my @cliparams = ('lunmap', '-p', $port, '-l', $found); # TODO: REPLACE to VAR
    $res = $execute_command->($scfg, 'ssh', $timeout, $targetcli, @cliparams);
    die $res->{msg} if !$res->{result};
    print $fh "ctladm lunmap -p $port -l $to_kill\n";


    # step 2: delete the plun
    @cliparams = ('remove', '-b block', "-l $pLUN" );
    print $fh "ctladm remove -b block -l $pLUN\n";
    $res = $execute_command->($scfg, 'ssh', $timeout, $targetcli, @cliparams);
    do {
        die $res->{msg};
    } unless $res->{result};
    
    #$free_lu_name->($volname);
   update_config($scfg);


    close $fh;
#    $res->{msg} = "STOP! STOP! STOP!";
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
    my $file = "/tmp/debug-runluncmd.log"; # TODO: kill
    open(my $fh, '>>', $file); # TODO: kill

    # fetch configuration from target if we haven't yet or if it is stale
    my $timediff = time - $SETTINGS_TIMESTAMP;
    if (!$SETTINGS || $timediff > $SETTINGS_MAXAGE) {
        $SETTINGS_TIMESTAMP = time;
        $parser->($scfg);
    }
    print $fh "Command $method, parameters:\n";
    print $fh Dumper(@params);
    die "unknown command '$method'" unless exists $lun_cmd_map{$method};
    my $msg = $lun_cmd_map{$method}->($scfg, $timeout, $method, @params);
    print $fh "Answer:\n";
    print $fh Dumper($msg);
    close $fh;
    return $msg;
}
