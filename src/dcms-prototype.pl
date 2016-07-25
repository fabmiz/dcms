#!/usr/bin/perl

use Data::Dumper qw(Dumper);

my %rec;
my %counter_val;
my @sw_lids;
my %in_cong;
my %in_vict;

my $low_threshold	= 10000;
my $high_threshold	= 27400000;
my $cong_threshold = 800000;

sub gen_topo
{

    if (`sudo ibnetdiscover -g > $topo_file`) {
		die "Execution of ibnetdiscover failed: $!\n";
	}
	return($topo_file);	
}

sub perfquery
{
	my $lid	 = $_[0];
	my $port = $_[1];
	my $type = "Wait";
	my $cmd = "/usr/bin/sudo perfquery $lid $port";
	
	if( $_[2] eq "Cong" ){
		$cmd = "/usr/bin/sudo perfquery --xmitcc $lid $port";
		$type = "CongTime";
	}

	my $output = qx($cmd);

	my $counter = "PortXmit" . $type;

	for my $line (split /[\r\n]+/,$output) {
		if( $line =~ /$counter/ ){
			my ($val) = $line =~ /(\d+)/;
			return($val);
		}
	}

}

sub parse_topo 
{
	my $topo = $_[0];
	
	open IBNET_TOPO, "<$topo"
	  or die "Failed to open ibnet topology: $!\n";
	
	my  $in_switch  	= "no";
	my	$loc_sw_lid 	= "";
	my	$loc_port 	= "";
	my	$line     	= "";

	my  $count		= 0;	

	while ($line = <IBNET_TOPO>) {
		if ($line =~ /^Switch.*\"S-.*\"\s+#.*\".*\".* lid (\d+).*/) {
			
			if ($count != 0){
				
				$rec{$loc_sw_lid}{loc_port}	= [@loc_ports];
				$rec{$loc_sw_lid}{rem_lid}	= [@rem_lids];
				$rec{$loc_sw_lid}{rem_port}	= [@rem_ports];
			}	

			$loc_sw_lid = $1;
			$in_switch  = "yes";
			@loc_ports 	= ();
			@rem_lids	= ();
			@rem_ports	= ();
			push @sw_lids, $loc_sw_lid;
			
			$in_cong{$sw_lid} = -1;
			$in_vict{$sw_lid} = -1;		

			$rec{$loc_sw_lid}{loc_port} = \@loc_ports;  	
			$rec{$loc_sw_lid}{rem_lid}  = \@rem_lids;
			$rec{$loc_sw_lid}{rem_port} = \@rem_ports;

			$count+=1;
		}

		if ($in_switch eq "yes") {
			
			if ($line =~
/^\[(\d+)\]\s+\"[HSR]-.+\"\[(\d+)\](\(.+\))?\s+#.*\".*\"\.* lid (\d+).*/
			  )
			{
				$loc_port = $1;
				my $rem_port      = $2;
				my $rem_lid       = $4;
				
				push @loc_ports, $loc_port;
				push @rem_lids, $rem_lid;
				push @rem_ports, $rem_port;
			}
		} 
		if ($line =~ /^Ca.*/ || $line =~ /^Rt.*/) { $in_switch = "no"; }
	}
	
	close IBNET_TOPO;
}

sub sweep
{
	my $sw_lid = $_[0];

	my @pcongs = ();
	my @pxwaits = ();	
	$counter_val{$sw_lid}{rem} = \@pxwaits;
	$counter_val{$sw_lid}{loc} = \@pcongs;
	
	my @loc_ports = @{ $rec{$sw_lid}{loc_port} };
	my @rem_lids = @{ $rec{$sw_lid}{rem_lid} };	

	for my $i (0..$#loc_ports){
		my $pcong = perfquery($sw_lid,$rec{$sw_lid}{loc_port}[$i],"CongTime");		
		push @pcongs,$pcong;
	}
	
	for my $i (0..$#rem_lids){
		my $pxwait = perfquery($rec{$sw_lid}{rem_lid}[$i],$rec{$sw_lid}{rem_port}[$i],"Wait");		
		push @pxwaits,$pxwait;
	}

	print "Vals after sweep \n";
	print Dumper \%counter_val;
	return(\%counter_val);

}

sub process_sweep

{

my %pre_vals = %{ $_[0] };
my %post_vals = %{ $_[1] };
my $sw_lid = $_[2]; 
	
print Dumper \%pre_vals;
print Dumper \%post_vals;

my @loc_ports_vals = $pre_vals{$sw_lid}{loc};

print "sdfdfds: $#loc_ports_vals\n";
for my $i (0..$#loc_ports_vals){

	my $diff = $post_vals{$sw_lid}{loc_port}[$i] - $pre_vals{$sw_lid}{loc_port}[$i];
	print $sw_lid . " : congdiff: " . $diff;

	if($diff <= $low_threshold && $in_cong{$sw_lid} == $i){
		$in_cong{$sw_lid} = -1;
		reset_params($sw_lid,$rec{$sw_lid}{loc_port}[$i],2048);			
		next;
	}
	if($diff > $cong_threshold){
		$in_cong{$sw_lid}=$i;		
		last;
	}
}

if($in_cong{$sw_lid} != -1){

	for my $i (0..$#loc_ports_vals){

		my $diff = $post_vals{$sw_lid}{rem_lid}[$i] - $pre_vals{$sw_lid}{rem_lid}[$i];
		
		if($diff <= $low_threshold && $in_vict{$sw_lid} == $i){
			$in_vict{$sw_lid} = -1;
			reset_params($sw_lid,$rec{$sw_lid}{loc_port}[$i],2048);			
			next;
		}
		
		if($diff >= $high_threshold){
			$in_vict{$sw_lid}=$i;		
			reset_params($sw_lid,$rec{$sw_lid}{loc_port}[$i],0);			
			return(1);
		}
	}

}
return(0);

}

sub reset_params
{
 	my $cmd = "./reset_CC ";
	$cmd .= $_[0];
	$cmd .= " ".$_[1];
	$cmd .= " ".$_[2]; 	
	system($cmd);
}

sub main{

my $ibnet_topo = $ARGV[0];

parse_topo($ibnet_topo);
print "ibnet topo successfully parsed....\n";

my $num_of_sw = @sw_lids; 

while (1){
	foreach my $sw_lid (@sw_lids){
		my %pre  = %{ sweep($sw_lid) };
		sleep(1);
		my %post = %{ sweep($sw_lid) };

		if(process_sweep(\%pre,\%post,$sw_lid)){
			print "Congestion found. Marking rate reset\n";
		} else {print "No congestion point found.\n";}
		
	}
}


}
main
