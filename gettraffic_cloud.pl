#!/usr/bin/perl -w

use strict;
use warnings;

use lib "/home/sites/preproduction.cp.king-servers.com/include/";
use MAIN;
use HTMLSUBS;
use Parallel::ForkManager;

use Net::SNMP;
use DBI;
use Fcntl qw(:flock);
use POSIX;
use bigint;

my $p;
my ($SELF,$SELFDIR) = (substr($0,($p=rindex($0,'/'))+1),$p<0?'.':substr($0,0,$p));
my $debug = 0;
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime time;
$year = $year + 1900;
$mon = $mon + 1;
my $my_unix_time = time;

my %oids = (
	'ifDescr' => '1.3.6.1.2.1.2.2.1.2',
	'ifInOctets' => '1.3.6.1.2.1.2.2.1.10',
	'ifOutOctets' => '1.3.6.1.2.1.2.2.1.16',
);


my %node_snmp_object_cache = ();

my ($snmp,$snmp_error, $info) = ('', '', '');

# subs
sub REAPER {
	my $child;
	while (($child = waitpid(-1,WNOHANG)) > 0) {
#		$status{$child} = $?;
	}
	local $SIG{CHLD} = \&REAPER;
	return;
}
local $SIG{CHLD} = \&REAPER;

sub dbConnect_tasks {
	# Attempt to make connection to the database
	my $dsn_tasks = "dbi:mysql:database=".$vars{'db_name'}.":host=".$vars{'db_host'}.":port=3306";
	my $dbh_tasks = DBI->connect ($dsn, $vars{'db_username'}, $vars{'db_password'}) or die $DBI::errstr;
	return ($dbh_tasks);
}

sub check_mysql {
	# Создаём в БД таблицу для хранения итогов
	my $query = "CREATE TABLE IF NOT EXISTS `" . $year . "_SNMP` (`unic_id` INT(12) NOT NULL AUTO_INCREMENT , `server_id` INT(10) NOT NULL , `month` int(8) NOT NULL , `day` INT(32) NOT NULL , `traff_in` BIGINT NOT NULL , `traff_out` BIGINT NOT NULL , `last_change` INT(255) NOT NULL, PRIMARY KEY (`unic_id`), INDEX (`server_id`, `month`, `day`))";
	my $sth = $dbh -> do("$query") or die;
	
	# Создаём в БД таблицу для хранения временных данных
	$query = "CREATE TABLE IF NOT EXISTS `SNMP_tmp_table` (`server_id` INT(255) NOT NULL, `unix_time` INT(255) NOT NULL, `traff_in_absolute` BIGINT NOT NULL, `traff_out_absolute` BIGINT NOT NULL, INDEX (`server_id`))";
	$sth = $dbh->do("$query") or die;
	return;
}

sub main {
	local $0 = "gettraffic_cloud [ master ]";
	my @dc_id = (79, 85, 84, 86);
	for(my $i = 0; $i < scalar(@dc_id); $i++){
		my $pid=fork;            
		next if $pid;
		local $0 = "gettraffic [ ".$dc_id[$i]." - $my_unix_time ]";
		get_traffic($dc_id[$i]);
		exit;
	}
	
	while((my $child=waitpid(-1,WNOHANG))>0){ sleep 1; }
	sleep;
	return;
}

sub get_traff_snmp {
	my ($server_id, $cloud_uuid, $dc) = @_;
	
	my $dbh = dbConnect_tasks();
	
	my ($traff_in, $traff_out) = (0, 0);
	
	
	my $sth_find_cloud_master = $dbh->prepare("get master");
	$sth_find_cloud_master->execute($dc);
	my ($server_ip) = $sth_find_cloud_master->fetchrow_array;
	
	my $dom_id = `/usr/bin/sudo $main_path/scripts/CHECKCLOUD $server_ip vm-param-get-dom-id $cloud_uuid`;
	$dom_id  =~ s/\n//g;
	$dom_id = trim($dom_id);
		
	if ($dom_id == -1){
		return;
	}
		
	my $vifDesc = "vif$dom_id.0";
	print "dom_id = $dom_id\n" if $debug;
	print "vifDesc = $vifDesc\n" if $debug;
	
	if (index($vifDesc, "vif.0") > -1){
		return;
	}
	
	if ($dom_id ne ''){
		my $vm_host = `/usr/bin/sudo $main_path/scripts/CHECKCLOUD $server_ip resident-on $cloud_uuid `;
		$vm_host =~ s/\n//g;
			
		my($info) = ('');
		
		if(exists $node_snmp_object_cache{$vm_host}){
			$info = $node_snmp_object_cache{$vm_host};
		} else {
			$info = 'error';
		}
		
		if($info eq 'error'){
			return;
		}
		
		foreach my $oid (grep {/^$oids{ifDescr}\./} keys(%$info)) {
			my($index) = $oid =~ m|\.(\d+)$|;
			if ( $info->{"$oids{ifDescr}.$index"} eq $vifDesc ) {
				print $info->{"$oids{ifDescr}.$index"}." ".$info->{"$oids{ifInOctets}.$index"}." ".$info->{"$oids{ifOutOctets}.$index"}."\n" if $debug;
				#результаты по траффику
				$traff_in += $info->{"$oids{ifInOctets}.$index"};
				$traff_out += $info->{"$oids{ifOutOctets}.$index"};
			}
		}
	}

 	if ( $traff_in == 0 || $traff_out == 0 ){ return; };
	unless(defined $traff_in){ return; };
	unless(defined $traff_out){ return; };
	print "\t\t $traff_in $traff_out\n" if $debug;

 	# лезем в БД с целью достать предыдущие значения счётчиков, для начала достаём максимальный UNIX TIME для этого интерфейса
	my $sth2 = $dbh->prepare("select max(unix_time) from SNMP_tmp_table where server_id = ?");
	$sth2->execute($server_id);
	my ($unix_time) = $sth2->fetchrow_array;

 	my ($traff_in_absolute, $traff_out_absolute ) = (0, 0);
	# достаём данные от предыдущего съёма статистики
	$sth2 = $dbh->prepare("select traff_in_absolute, traff_out_absolute from SNMP_tmp_table where server_id = ? and unix_time = ?");
	$sth2->execute($server_id, $unix_time);
	($traff_in_absolute, $traff_out_absolute) = $sth2->fetchrow_array;

 	unless($traff_in_absolute =~ /^[0-9]{1,}$/){ $traff_in_absolute = 0; }
	unless($traff_out_absolute =~ /^[0-9]{1,}$/){ $traff_out_absolute = 0; }
	#проверяем, больше, или меньше текущее значение, чем предыдущее, на случай, что счётчики сбрасывались, между измерениями
	my $delta_traff_in = 0;
	my $delta_traff_out = 0;
	if ( ($traff_in - $traff_in_absolute > ($my_unix_time - $unix_time) * 125000000 * 4 or $traff_out - $traff_out_absolute > ($my_unix_time - $unix_time) * 125000000 * 4) && ($traff_in_absolute !=0 and $traff_out_absolute !=0 ) ) {
		#print "$server_id, $mon, $mday, $my_unix_time\n" if $debug;
		#print "\t$traff_in >= $traff_in_absolute, $traff_out >= $traff_out_absolute\n";
		#$traff_in = $traff_in_absolute;
		#$traff_out = $traff_out_absolute;
		return;
	}
		
 	if($traff_in >= $traff_in_absolute){ $delta_traff_in = $traff_in - $traff_in_absolute; }
	if($traff_out >= $traff_out_absolute){ $delta_traff_out = $traff_out - $traff_out_absolute; }

	$sth2 = $dbh->prepare("insert into SNMP_tmp_table(server_id,unix_time,traff_in_absolute,traff_out_absolute) values(?, ?, ?, ?)");
	$sth2->execute($server_id, $my_unix_time, $traff_in, $traff_out);

 	$sth2 = $dbh->prepare("select count(*) from ".$year."_SNMP where server_id = ? and month = ? and day = ?");
	$sth2->execute($server_id, $mon, $mday);
	my ($cnt) = $sth2->fetchrow_array;

 	if ( $cnt == 0 ){
		$sth2 = $dbh->prepare("insert into ".$year."_SNMP(server_id, month, day, traff_in, traff_out, last_change) values(?, ?, ?, '0', '0', ?) ");
		$sth2->execute($server_id, $mon, $mday, $my_unix_time);
	} else {
		$sth2 = $dbh->prepare("update ".$year."_SNMP set traff_in=traff_in+$delta_traff_in, traff_out=traff_out+$delta_traff_out, last_change = ? where server_id = ? and month = ? and day = ?");
		$sth2->execute($my_unix_time, $server_id, $mon, $mday)
	}
	
	return;
}

sub get_traffic {
	my ( $dc ) = @_;
	print "$dc\n" if $debug;
	my $dsn = "dbi:mysql:database=".$vars{'db_name'}.":host=".$vars{'db_host'}.":port=3306";
	my $dbh = DBI->connect ($dsn, $vars{'db_username'}, $vars{'db_password'}) or die $DBI::errstr;
		die "Undefined error\n" if $?;
	
	my $sth_find_cloud_master = $dbh->prepare("need to get cloud master");
	$sth_find_cloud_master->execute($dc);
	my ($server_ip) = $sth_find_cloud_master->fetchrow_array;
	
	my $sth = $dbh->prepare("ips of nodes");
	$sth->execute($dc);
	
	my $list_hosts = `/usr/bin/sudo $main_path/scripts/CHECKCLOUD $server_ip hosts-list`;
	print "list_hosts=$list_hosts\n" if $debug;
	$list_hosts  =~ s/\n//g;
	my (@hosts_uuid) = split(",", $list_hosts);
	my $hosts_cnt = scalar(@hosts_uuid);
	
	my @nodes_ips = ();
	while (my ($node_main_ip) = $sth->fetchrow_array) {
		push(@nodes_ips, $node_main_ip);
	}
	
	for(my $i = 0; $i < $hosts_cnt; $i++){
		my $curr_node_ip = `/usr/bin/sudo $main_path/scripts/CHECKCLOUD $server_ip param-name_addr $hosts_uuid[$i]`;
		$curr_node_ip =~ s/\n//g;
		print "curr_node_ip=$curr_node_ip\n" if $debug;
		for(my $j = 0; $j < scalar(@nodes_ips);$j++) {
			if($curr_node_ip eq $nodes_ips[$j]) {
				
				($snmp,$snmp_error) = Net::SNMP->session(-hostname => $curr_node_ip, -community => 'public', );
				
				if (!$snmp) {
					print "Couldn't create snmp object for $server_ip: $snmp_error\n" if $debug;
					$node_snmp_object_cache{$hosts_uuid[$i]} = 'error';
					last;
				}
				
				$info = $snmp->get_entries(-columns => [ $oids{ifDescr}, $oids{ifInOctets}, $oids{ifOutOctets} ]);
				if (!$info) {
					print "Couldn't poll $server_ip: %s\n"." ".$snmp->error();
					$node_snmp_object_cache{$hosts_uuid[$i]} = 'error';
					last;
				}
				my %tmp_hash = %$info;
				$node_snmp_object_cache{$hosts_uuid[$i]} = \%tmp_hash;
				$snmp->close();
				last;
			}
			
		}
	}
	
	$sth = $dbh->prepare("list of vds");
	$sth->execute($dc);
	
	my $pm = Parallel::ForkManager->new(4);
	#$pm->set_waitpid_blocking_sleep(0);
	
	while (my ($server_id, $cloud_uuid) = $sth->fetchrow_array) {
		
 		if($cloud_uuid eq ''){
			next;
		}
		
		$pm->start and next;	
		get_traff_snmp($server_id, $cloud_uuid, $dc);
    		$pm->finish;
	}

	$pm->wait_all_children;
	
	
	return;
}

# main part
my $FH;
unless(open($FH,"<",$0)){
  print STDERR "$$: Cannot open $0 - $!\n";
  die;
}

unless(flock($FH, LOCK_EX|LOCK_NB)){
  print STDERR "$$: Already running.\n";
  die;
}

check_mysql();
main();
close($FH) or die "unable to close: $!\n";
