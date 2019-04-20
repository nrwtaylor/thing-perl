#!/usr/bin/perl

#### Module     : Perl Thing
#### Author     : NRWTaylor <nrwtaylor@gmail.com>
#### Created on : 20 APRIL 2019

use strict;
use warnings;
use Gearman::Client;

use IO::Handle;

use Time::HiRes qw( time );

use JSON;

use Data::Dumper;

my $client = Gearman::Client->new;
$client->job_servers('127.0.0.1');

# Using JSON to serialize and deserialize Gearman jobs
my $json = JSON->new;

my $thing;    #sure

# key thing is to open a read/write serial port
# as simply as the OS will permit
# I imagine this as Thing-Perl

my $number;

my $input;

# responsive to
my @keywords = (
    "AT",    "ATI",   "+CMTI", "+CNUM", "+SMS FULL", "ping",
    "kaiju", "thing", "clocktime"
);

my @num_whitelist = ();
my @num_stacklist = ();

my $port = "/dev/ttyUSB0";

my $char;

my $flag;

my $sms_available_bytes;

my $to;
my $filtered_input;

my $response;

my $flag_thing = "green";

my $search_string = "";
my $search_for    = "";
my $instruction   = "";
my $agent         = "";
my $prior_agent   = "";

my $current_millis = time;
my $tick_interval  = 1;
my $tick_millis    = time;

my $ticks      = 0;
my $tick_limit = 3;

my $sms_budget     = 0;
my $sms_budget_max = 1;
my $sms_quota      = 0;
my $sms_quota_max  = 20;    # Allow agent to send up to 3 messages in N bars
my $priority_quota = 0;
my $priority_quota_max =
  1;    # Allow user to send up to 1 priority messages per 80 bar
my $stack_quota = 0;
my $stack_quota_max =
  2;    # Allow user to send up to 2 priority messages per 80 bar
my $display_budget     = 0;
my $display_budget_max = 1;

#my $sms_serial_buffer = ".";
my $sms_serial_buffer = "";
my $sms_serial_buffer_length =
  160;    # design to accept maximum anticipated +CMGR frame

my $state = 0;    #false

my @thing_report;

my $flag_priority = 0;

# bar
my $bar       = 0;
my $bar_limit = 80;

# id
my $uuid  = "0000-0000-0000-0000-000000000000";
my $nuuid = "0000";
my $id;

# meta
my $nom_from = "null";
my $subject;
my $created_at;
my $nom_to;

# time
my ( $s, $m, $h, $D, $M, $Y );

open( COM, "+<", $port ) || die "Cannot read serial port : $!\n";

# Switch COM port to non-blocking operation.
use Fcntl;
my $flags |= O_NONBLOCK;
fcntl( COM, F_SETFL, $flags ) or die "Couldn't set flags for HANDLE: $!\n";

setup();
while (1) { loop(); }

sub loop {
    $agent          = "agent";
    $current_millis = time;
    doHear();    # throw in a listen
    if ( isAgent() ) {

        doLog("Heard an agent.");
        doRespond();
    }
    else {
        # No agent heard. Wipe buffer.
        $sms_serial_buffer = "";
    }

    #    isAgent(); # see what Agents there are
    if ( ( $current_millis - $tick_millis ) >= $tick_interval ) {

        doTick();
        $tick_millis = $current_millis;
    }

    #   $response .= "Loop run. ";
    if ( $agent eq "" ) { $agent = "loop"; }
}

sub setup {
    doWhitelist();
    doStacklist();
    doStart();
}

sub doLog {

}

sub doStart {

    my $filename = 'eeprom.txt';
    if ( open( my $fh, '<:encoding(UTF-8)', $filename ) ) {
        while ( my $stored_state = <$fh> ) {
            chomp $stored_state;
            if ( $stored_state eq "start" ) {
                $state = "stop";    # false
            }
            if ( $stored_state eq "stop" ) {
                $state = "start";    # true
                                     # write 255
            }
        }
    }
    else {
        warn "Could not open file '$filename' $!";
        open( my $fh, '>', $filename );
        print $fh "start\n";
        close $fh;
    }

    print COM "AT";
    print COM "\x0D";
    print COM "\x0A";

    doListen("OK");

    print COM "AT+CMGF=1";
    print COM "\x0D";
    print COM "\x0A";

    doListen("OK");

    print COM "AT+CNUM";
    print COM "\x0D";
    print COM "\x0A";

    doListen("OK");

    doNumber();

    # read state to read from eeprom.
    if ($state) {
        $response = "Started.";
    }
    else {
        $response = "Squawk.";
    }

    if ( index( lc($agent), "start" ) != -1 ) {
        doMessage();
    }
    if ( $agent eq "" ) { $agent = "start"; }
}

sub doWhitelist {

    my $filename = 'whitelist.txt';
    if ( open( my $fh, '<:encoding(UTF-8)', $filename ) ) {
        while ( my $row = <$fh> ) {
            chomp $row;
            push( @num_whitelist, $row );

        }
    }
    else {
        warn "Could not open file '$filename' $!";
        open( my $fh, '>', $filename );
        print $fh "start\n";
        close $fh;
    }
    return;
}

sub doStacklist {

    my $filename = 'stacklist.txt';
    if ( open( my $fh, '<:encoding(UTF-8)', $filename ) ) {
        while ( my $row = <$fh> ) {
            chomp $row;
            push( @num_stacklist, $row );

        }
    }
    else {
        warn "Could not open file '$filename' $!";
        open( my $fh, '>', $filename );
        print $fh "start\n";
        close $fh;
    }
    return;
}

sub isHit {

    if ( doListen() ) {
        doRespond();
        return 1;
    }
    return 0;
}

sub isAgent {

    # Quickly establish if stream/channel mentions an agent we are watching for.
    $number = undef;

    my $sms_millis = time;
    $flag = 0;    #false

    # maybe don't need this in perl. Let's see.
    #int fp = sms_pointer_write;
    while ( ( time - $sms_millis ) <= 2 ) {

        # do we need to check for buttons?
        #doHear();

        foreach my $search_for (@num_whitelist) {
            if ( doListen() ) {
                doRespond();
            }
        }

        # Now listen for a one of the keywords
        foreach my $keyword (@keywords) {
            $search_for = $keyword;
            if ( isHit() ) {
                return 1;    #true;
            }
        }

    }
    return 0;                #false
}

sub doId {
    if ( !defined $number ) { return; }
    $id = $number;
}

sub doBuffer {
    my $temp_string = $sms_serial_buffer;
    local $/ = "\r\n";
    chomp $temp_string;

    local $/ = "\n";
    chomp $temp_string;

    doLog( "Buffer is " . $temp_string . ". " );

}

sub doClocktime {

    my $time = time;
    ( $s, $m, $h, $D, $M, $Y ) = localtime($time);

}

sub doCron {

    # dev

}

sub doListen {
    my $agent_instruction = @_;
    if ( $agent_instruction != 0 ) { $search_for = $agent_instruction; }
    my $match = 0;    #false

    # nothing to listen to
    if ( $search_for eq "" ) {

        # blank
        return;
    }

    if ( !defined $sms_serial_buffer ) {
        return 0;
    }

    if ( index( lc($sms_serial_buffer), lc($search_for) ) != -1 ) {

        $match = 1;
    }

    #Action on the first match.  To avoid re-reads.
    # dev
    # remove matched text
    if ($match) {
        $agent = lc($search_for);

        my $sp = index( lc($sms_serial_buffer), lc($search_for) );
        my $ln;
        if ( $sp != -1 ) {
            $ln    = length($search_for);
            $agent = $search_for;

            my $x_pad = ( 'X' x $ln );

            substr( $sms_serial_buffer, $sp, $ln ) = $x_pad;

        }
    }

    return $match;

}

sub doThing {
    my $agent_instruction = @_;
    if ( $agent_instruction != 0 ) {

        # no action
    }

    $agent    = "thing";
    $response = "quiet";

}

sub doStack {

    doLog("asked to call the Stack");

    my $data_to_json = { to => $to, from => $nom_from, subject => $subject };

    my $datagram = $json->encode($data_to_json);
    my $json_response;

    my $tasks  = $client->new_task_set;
    my $handle = $tasks->add_task(
        call_agent => $datagram,
        {
            on_complete => sub { $json_response = ${ $_[0] }, "\n" }
        }
    );
    $tasks->wait();

    if ( $json_response eq '' ) {

        # Did not get a stack response.
        # Generate a local response;
        doThing("quiet");
    }
    else {

        my $answer;
        $answer = $json->decode($json_response);

        doThing("loud");
        if ( defined( $answer->{'sms'} ) ) { $response = $answer->{'sms'}; }
    }

    if ( $agent eq "" ) { $agent = "stack"; }
}

sub doRespond {

    # Here the algorithm screens against locally available agent responses.

    $flag = 0;    #false

    foreach my $id (@num_whitelist) {

        #        if (index($input, $id) != -1) {
        if ( index( $agent, $id ) != -1 ) {
            $nom_from = $id;
        }
    }

    foreach my $stack_id (@num_stacklist) {
        if ( index( $nom_from, $stack_id ) != -1 ) {

            doLog("heard a stack id");
            doStack();
        }
    }

    $search_for = "ping";
    if ( lc($agent) eq lc($search_for) ) {
        doPing();
        $flag = 1;
        return;
    }

    $search_for = "+CMTI";
    if ( index( $agent, $search_for ) != -1 ) {
        doHayes();
        return;
    }

    $search_for = "+CNUM";
    if ( index( $agent, $search_for ) != -1 ) {
        doHayes();
        return;
    }

    $search_for = "+SMS FULL";
    if ( index( $agent, $search_for ) != -1 ) {
        doForget();
        return;
    }

    $search_for = ">";
    if ( index( $agent, $search_for ) != -1 ) {
        doHayes();
        return;
    }

}

sub doSerial {
    print uc($agent);
    print "\n";
    print $response;
    print "\n";
}

sub doConsole {
    if ( $response eq "" ) {
        print "tick "
          . $ticks . " bar "
          . $bar
          . " clocktime "
          . sprintf( "%02d", $h ) . ":"
          . sprintf( "%02d", $m )
          . "     \r";
        return;
    }

    if ( $agent eq ">" ) {
	print "\n";
	print $subject;

        my @lines = split /\|/, $response;

        if ( defined( $lines[0] ) ) {
            $agent = $lines[0];
            $agent =~ s/^\s+|\s+$//g;
        }

        if ( defined( $lines[1] ) ) {
            $response = $lines[1];
            $response =~ s/^\s+|\s+$//g;
        }

        if ( defined( $lines[2] ) ) {
            my $log = $lines[2];
            $log =~ s/^\s+|\s+$//g;
        }

        print "\n";
        print uc($agent);
        print "\n";
        print $response;
        print "\n";
    }
}

sub doFrom {
    if ( !defined $number ) { return; }
    $nom_from = $number;

}

sub doSMS {

    # Shouldn't need to do this if the XXXX'ing is working
    my $match = 0;

    my $do_not_send = 0;    # false

    doLog("asked to send a SMS");

    doLog( "sms_budget " . $sms_budget . "/" . $sms_budget_max . ". " );
    doLog( "sms_quota " . $sms_quota . "/" . $sms_quota_max . ". " );

    if ( $sms_budget <= 0 ) {

        #$response .=  "No SMS budget available. ";
        $do_not_send = 1;    #true
    }

    if ( $sms_quota >= $sms_quota_max ) {

        doLog("SMS quota exceeded");

        $do_not_send = 1;    #true
    }

    foreach my $sms_id (@num_whitelist) {

        if ( index( $nom_from, $sms_id ) != -1 ) {

            doLog("nominal matched");
            $match = 1;      # true
        }
    }

    foreach my $stack_id (@num_stacklist) {
        if ( index( $agent, $stack_id ) != -1 ) {
            doLog("stack number recognized");

            # dev no action yet
        }
    }

    if ( !$match ) {

        doLog("no agents seen");
        $do_not_send = 1;    #true
    }

    if (    ( $stack_quota >= $stack_quota_max )
        and ( index( $nom_from, $num_stacklist[0] ) != 1 ) )
    {
        # quota for stack messages exceeded
        doLog("quota for stack messages exceeded");
        $do_not_send = 1;    #true
    }

    if ($do_not_send) {
        $nom_from    = "null";
        $instruction = "subtract";

        doBudget();
        return;
    }

    doLog( "addressed message to " . $nom_from . "" );

    my $split_millis = time;
    $search_for = "OK";
    while ( !doListen() ) {
        if ( ( time - $split_millis ) >= 2 ) {
            last;
        }
        doHear();
    }

    if ( $response eq "" )     { return; }
    if ( $nom_from eq "null" ) { return; }

    print COM 'AT+CMGS="';

    print COM $nom_from;
    print COM '"';
    print COM "\x0D";
    print COM "\x0A";

    $split_millis = time;
    $search_for   = ">";
    while ( !doListen() ) {
        if ( ( time - $split_millis ) >= 2 ) {
            last;
        }
        doHear();
    }

    # Reformulate response to send as SMS
    my $sms_response = substr( $response, 0, 140 );
    print COM $sms_response;

    sleep(0.5);

    print COM "\x1A";
    print COM "\x0D";
    print COM "\x0A";

    sleep(0.5);

    $instruction = "subtract";
    doBudget();
    doQuota();
    $flag_priority = 0;    # false

    $nom_from = "null";

    #$sms_serial_buffer = "";
    #$response .= "And sent a SMS. ";
    if ( $agent eq "" ) { $agent = "sms"; }

    return;

}

sub doHayes {

    #$response .= "Asked to processed a Hayes string. ";

    #doStack();

    if ( $agent eq "AT" ) {
        doListen("OK");

        #$response .=  "OK";
    }

    if ( index( $agent, "ATI" ) != -1 ) {
        doListen("OK");

        doLog("system is not yet described");
    }

    if ( $agent eq ">" ) {
        print COM $response;
        sleep(0.5);
        print COM "\x1A";
        sleep(0.5);

        doListen("OK");
    }

    if ( $agent eq "+CMTI" ) {

        doLog("received a new message alert");

        $instruction = "add";
        doBudget();

        doNumber();

        doSubject();

        doStack();

        doMessage();
    }

    if ( $agent eq "+SMS FULL" ) {

        doLog("saw SMS mailbox is Full");
        $instruction = "add";
        doForget();
    }

    if ( $agent eq "+CNUM" ) {

        doNumber();
        doNumber();
        doId();

        doNumber();

        doLog( "saw our sms number - " . $id . ". " );
        return;
    }

    if ( $agent eq "" ) { $agent = "hayes"; }
}

sub doSubject {

    # which means taking a number
    # and reading the subject line

    # clear buffer;
    $sms_serial_buffer = "";

    print COM "AT+CMGR=";
    print COM $number;
    print COM "\x0D";
    print COM "\x0A";
    sleep(1);
    doHear();

    my @output = split( /\n/, $sms_serial_buffer );

    $flag = 0;
    my $meta;
    foreach my $line (@output) {

        if ($flag) {
            $subject = $line;
            last;
        }

        if ( index( $line, "\+CMGR:" ) != -1 ) {
            doLog("line contains CMGR");
            $meta = $line;
            $flag = 1;
        }

    }
    doLog( "subject " . $subject );
    doLog( "meta " . $meta );

    foreach my $id (@num_whitelist) {

        if ( index( $meta, $id ) != -1 ) {
            $nom_from = $id;
        }
    }
    doLog( "nom_from " . $nom_from );

    return;
}

sub doNumbers {
    while ( doNumber() ) {
    }

}

sub doQuota {

    doLog( "sms_quota " . $sms_quota . "/" . $sms_quota_max . ". " );
    if ( $instruction eq "reset" ) {
        $sms_quota = 0;
    }

    ++$sms_quota;
    $instruction = "";
    if ( $sms_quota > $sms_quota_max ) {
        $sms_quota = $sms_quota_max;
        return 0;    #false
    }

    return 1;        #true
}

sub doBudget {

    doLog( "sms_budget " . $sms_budget . "/" . $sms_budget_max . ". " );
    doLog( $instruction . " " );

    if ( $instruction eq "add" ) {
        ++$sms_budget;

        if ( $sms_budget >= $sms_budget_max ) {
            $sms_budget = $sms_budget_max;
        }

        doLog( "budget added and is now " . $sms_budget );

    }

    # Stack budget. Always okay to say something.
    $display_budget = 1;

    # Thing budget. There is a limit.
    if ( $instruction eq "subtract" ) {
        if ( $sms_budget == 0 ) {

            # clear the instruction
            $instruction = "";

            return 0;    #false;
        }
        --$sms_budget;
    }

    # clear the instruction
    $instruction = "";

    if ( $sms_budget > 0 ) {
        return 1;        #true;
    }

    return 0;            # false
}

sub doNumber {

    $flag = 0;

    my @numeric_variables = $sms_serial_buffer =~ /(\d+)/g;

    if ( !defined $numeric_variables[0] ) {
        return 0;        #false
    }
    else {
        $number = $numeric_variables[0];

        # wipe the number
        doListen($number);
    }

    if ( $agent eq "" ) { $agent = "number"; }

    doLog( "number is " . $number );
    if ( $agent eq "" ) { $agent = "number"; }

    #return $number;
    return 1;    #true
}

sub doPing {

    $response = "Pong. ";

    if ( lc($agent) eq "ping" ) {
        doMessage();
    }
    $agent = "ping";    # because an action was taken with agency
                        #if ($agent eq "") {$agent = "ping";}
}

sub doTick {

    # Local sense functions
    # doAccelerometer();
    # doCompass();
    # doTesla();
    doClocktime();

    # That kind of thing.

    $ticks = $ticks + 1;

    my $temp_string = $sms_serial_buffer;
    local $/ = "\r\n";
    chomp $temp_string;

    local $/ = "\n";
    chomp $temp_string;

    if ( $ticks > $tick_limit ) {
        $ticks = 0;
        doBar();
    }

    doLog("ticked a beat");

    doMessage();

    if ( $agent eq "" ) { $agent = "tick"; }
}

sub doAgent {

    # Implement a simple round robin.
    # tick_interval determines how quickly the round is run.

    # locally calculated easily
    my $index = $bar % $bar_limit;
    if ( $bar == 0 ) {
        $instruction = "reset";
        doQuota();
    }

    doIndex($index);
}

sub doIndex {
}

sub doMessage {
    doSMS();
    doConsole();

    # Reset response.
    $response = "";
    $subject  = "";
    $nom_from = "";
}

sub doHear {

    # read waiting bytes from buffer
    my $num_bytes    = 0;
    my $split_millis = time;
    while ( ( time - $split_millis ) <= 2000 ) {
        my $in = <COM>;

        if ( !defined $in ) { last; }
        $num_bytes += length($in);

        if ( ( defined $sms_serial_buffer ) and ( !defined $in ) ) { last; }

        if ( ( !defined $sms_serial_buffer ) and ( defined $in ) ) {
            $sms_serial_buffer = $in;
            last;
        }

        $sms_serial_buffer .= $in;
    }

    # Do not need to do the Arduino hurdle of character-wise work.
    # Can use direct string-wise functions to the same work.

    my $trim_length = $sms_serial_buffer_length - $num_bytes;

    # https://www.perlmonks.org/?node_id=97571
    # my $str = "1234567890\n";
    # $str =~ s/^.{$n}//s;

    if ( !( length($sms_serial_buffer) < $sms_serial_buffer_length ) ) {

        $sms_serial_buffer =~ s/^.{$trim_length}//s;
    }

    # And then take one more off.
    my $n = 1;
    $sms_serial_buffer =~ s/^.{$n}//s;

}

sub doBar {
    $bar++;

    if ( $bar > $bar_limit ) {
        $bar = 0;
    }

    # Check the clock each and every bar.  Minimum.
    doCron();

    $prior_agent = $agent;

    doLog( "Set bar to " . $bar . ". " );
    if ( $agent eq "" ) { $agent = "bar"; }
}

sub doForget {

    print COM "AT+CMGD=0,4";
    print COM "\x0D";
    print COM "\x0A";

    sleep(1);

    $response = "Forgot messages.";
    if ( $agent eq "" ) { $agent = "forget"; }
    return;
}
