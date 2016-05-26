#!/usr/bin/perl
#
#  Copyright (c) 2011 Opera Software Australia Pty. Ltd.  All rights
#  reserved.
#
#  Redistribution and use in source and binary forms, with or without
#  modification, are permitted provided that the following conditions
#  are met:
#
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in
#     the documentation and/or other materials provided with the
#     distribution.
#
#  3. The name "Opera Software Australia" must not be used to
#     endorse or promote products derived from this software without
#     prior written permission. For permission or any legal
#     details, please contact
# 	Opera Software Australia Pty. Ltd.
# 	Level 50, 120 Collins St
# 	Melbourne 3000
# 	Victoria
# 	Australia
#
#  4. Redistributions of any form whatsoever must retain the following
#     acknowledgment:
#     "This product includes software developed by Opera Software
#     Australia Pty. Ltd."
#
#  OPERA SOFTWARE AUSTRALIA DISCLAIMS ALL WARRANTIES WITH REGARD TO
#  THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
#  AND FITNESS, IN NO EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE
#  FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
#  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
#  AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
#  OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

use strict;
use warnings;

package Cassandane::Cyrus::CaldavAlarm;
use base qw(Cassandane::Cyrus::TestCase);
use DateTime;
use DateTime::Format::ISO8601;
use Cassandane::Util::Log;
use JSON::XS;
use Net::CalDAVTalk;
use Data::Dumper;
use POSIX;
use Carp;

sub new
{
    my $class = shift;

    my $config = Cassandane::Config->default()->clone();
    $config->set(caldav_realm => 'Cassandane');
    $config->set(httpmodules => 'caldav');
    $config->set(httpallowcompress => 'no');
    $config->set(sasl_mech_list => 'PLAIN LOGIN');
    return $class->SUPER::new({
	config => $config,
        adminstore => 1,
	services => ['imap', 'http'],
    }, @_);
}

sub set_up
{
    my ($self) = @_;
    $self->SUPER::set_up();
    my $service = $self->{instance}->get_service("http");
    $ENV{DEBUGDAV} = 1;
    $self->{caldav} = Net::CalDAVTalk->new(
	user => 'cassandane',
	password => 'pass',
	host => $service->host(),
	port => $service->port(),
	scheme => 'http',
	url => '/',
	expandurl => 1,
    );

    if (not $self->{instance}->{buildinfo}->{component}->{calalarmd}) {
        xlog "calalarmd not enabled. Skipping tests.";
        return;
    }
    $self->{test_calalarmd} = 1;

}

sub _can_match {
    my $event = shift;
    my $want = shift;

    # I wrote a really good one of these for Caldav, but this will do for now
    foreach my $key (keys %$want) {
        return 0 if not exists $event->{$key};
        return 0 if $event->{$key} ne $want->{$key};
    }

    return 1;
}

sub assert_alarms {
    my $self = shift;
    my @want = @_;
    # pick first calendar alarm from notifications
    my $data = $self->{instance}->getnotify();
    if ($self->{replica}) {
        my $more = $self->{replica}->getnotify();
        push @$data, @$more;
    }
    my @events;
    foreach (@$data) {
        if ($_->{CLASS} eq 'EVENT') {
            my $e = decode_json($_->{MESSAGE});
            if ($e->{event} eq "CalendarAlarm") {
                push @events, $e;
            }
        }
    }

    my @left;
    while (my $event = shift @events) {
        my $found = 0;
        my @newwant;
        foreach my $data (@want) {
            if (not $found and _can_match($event, $data)) {
                $found = 1;
            }
            else {
                push @newwant, $data;
            }
        }
        if (not $found) {
            push @left, $event;
        }
        @want = @newwant;
    }


    Carp::confess(Data::Dumper::Dumper(\@want, \@left)) if (@want or @left);
}

sub tear_down
{
    my ($self) = @_;

    $self->SUPER::tear_down();
}

sub test_simple
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo'});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define the event to start in a few seconds
    my $startdt = $now->clone();
    $startdt->add(DateTime::Duration->new(seconds => 2));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 15));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "574E2CD0-2D2A-4554-8B63-C7504481D3A9";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Australia/Sydney
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4
TZOFFSETFROM:+1100
TZOFFSETTO:+1000
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10
TZOFFSETFROM:+1000
TZOFFSETTO:+1100
END:DAYLIGHT
END:VTIMEZONE

BEGIN:VEVENT
CREATED:20150806T234327Z
UID:574E2CD0-2D2A-4554-8B63-C7504481D3A9
DTEND;TZID=Australia/Sydney:$end
TRANSP:OPAQUE
SUMMARY:Simple
DTSTART;TZID=Australia/Sydney:$start
DTSTAMP:20150806T234327Z
SEQUENCE:0
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 60 );

    $self->assert_alarms({summary => 'Simple', start => $start});
}

sub test_override
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo'});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define an event that started almost an hour ago and repeats hourly
    my $startdt = $now->clone();
    $startdt->subtract(DateTime::Duration->new(minutes => 59, seconds => 55));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 15));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # the next event will start in a few seconds
    my $recuriddt = $now->clone();
    $recuriddt->add(DateTime::Duration->new(seconds => 5));
    my $recurid = $recuriddt->strftime('%Y%m%dT%H%M%S');

    my $rstartdt = $recuriddt->clone();
    my $recurstart = $recuriddt->strftime('%Y%m%dT%H%M%S');

    my $renddt = $rstartdt->clone();
    $renddt->add(DateTime::Duration->new(seconds => 15));
    my $recurend = $renddt->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "574E2CD0-2D2A-4554-8B63-C7504481D3A9";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.11.1//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Australia/Sydney
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4
TZOFFSETFROM:+1100
TZOFFSETTO:+1000
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10
TZOFFSETFROM:+1000
TZOFFSETTO:+1100
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
TRANSP:OPAQUE
DTEND;TZID=Australia/Sydney:$end
UID:12A08570-CF92-4418-986C-6173001AB557
DTSTAMP:20160420T141259Z
SEQUENCE:0
SUMMARY:main
DTSTART;TZID=Australia/Sydney:$start
CREATED:20160420T141217Z
RRULE:FREQ=HOURLY;INTERVAL=1;COUNT=3
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alert
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
BEGIN:VEVENT
CREATED:20160420T141217Z
UID:12A08570-CF92-4418-986C-6173001AB557
DTEND;TZID=Australia/Sydney:$recurend
TRANSP:OPAQUE
SUMMARY:exception
DTSTART;TZID=Australia/Sydney:$recurstart
DTSTAMP:20160420T141312Z
SEQUENCE:0
RECURRENCE-ID;TZID=Australia/Sydney:$recurid
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm exception
DESCRIPTION:My alarm exception has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    # trigger processing of alarms
    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 60 );

    $self->assert_alarms({summary => 'exception', start => $recurstart});
}

sub test_override_exception
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo'});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define an event that started almost an hour ago and repeats hourly
    my $startdt = $now->clone();
    $startdt->subtract(DateTime::Duration->new(minutes => 59, seconds => 55));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 15));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # the next event will start in a few seconds
    my $recuriddt = $now->clone();
    $recuriddt->add(DateTime::Duration->new(seconds => 5));
    my $recurid = $recuriddt->strftime('%Y%m%dT%H%M%S');

    # but it starts a few seconds after the regular start
    my $rstartdt = $now->clone();
    $rstartdt->add(DateTime::Duration->new(seconds => 15));
    my $recurstart = $rstartdt->strftime('%Y%m%dT%H%M%S');

    my $renddt = $rstartdt->clone();
    $renddt->add(DateTime::Duration->new(seconds => 15));
    my $recurend = $renddt->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "574E2CD0-2D2A-4554-8B63-C7504481D3A9";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.11.1//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Australia/Sydney
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4
TZOFFSETFROM:+1100
TZOFFSETTO:+1000
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10
TZOFFSETFROM:+1000
TZOFFSETTO:+1100
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
TRANSP:OPAQUE
DTEND;TZID=Australia/Sydney:$end
UID:12A08570-CF92-4418-986C-6173001AB557
DTSTAMP:20160420T141259Z
SEQUENCE:0
SUMMARY:main
DTSTART;TZID=Australia/Sydney:$start
CREATED:20160420T141217Z
RRULE:FREQ=HOURLY;INTERVAL=1;COUNT=3
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alert
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
BEGIN:VEVENT
CREATED:20160420T141217Z
UID:12A08570-CF92-4418-986C-6173001AB557
DTEND;TZID=Australia/Sydney:$recurend
TRANSP:OPAQUE
SUMMARY:exception
DTSTART;TZID=Australia/Sydney:$recurstart
DTSTAMP:20160420T141312Z
SEQUENCE:0
RECURRENCE-ID;TZID=Australia/Sydney:$recurid
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm exception
DESCRIPTION:My alarm exception has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    # trigger processing of alarms
    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 60 );

    $self->assert_alarms({summary => 'exception', start => $recurstart});
}

sub test_floating_notz
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo'});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define the event to start in a few seconds
    my $startdt = $now->clone();
    $startdt->add(DateTime::Duration->new(seconds => 2));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $utc = DateTime::Format::ISO8601->new->parse_datetime($start . 'Z');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 15));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "95989f3d-575f-4828-9610-6f16b9d54d04";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
CREATED:20150806T234327Z
UID:574E2CD0-2D2A-4554-8B63-C7504481D3A9
DTEND:$end
TRANSP:OPAQUE
SUMMARY:Floating
DTSTART:$start
DTSTAMP:20150806T234327Z
SEQUENCE:0
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 60 );

    $self->assert_alarms();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $utc->epoch() - 60 );

    $self->assert_alarms();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $utc->epoch() + 60 );

    $self->assert_alarms({summary => 'Floating', start => $start, timezone => '[floating]'});
}

sub test_floating_sametz
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $tz = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Australia/Sydney
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4
TZOFFSETFROM:+1100
TZOFFSETTO:+1000
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10
TZOFFSETFROM:+1000
TZOFFSETTO:+1100
END:DAYLIGHT
END:VTIMEZONE
END:VCALENDAR
EOF

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo', timezone => $tz});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define the event to start in a few seconds
    my $startdt = $now->clone();
    $startdt->add(DateTime::Duration->new(seconds => 2));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 15));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "95989f3d-575f-4828-9610-6f16b9d54d04";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
CREATED:20150806T234327Z
UID:574E2CD0-2D2A-4554-8B63-C7504481D3A9
DTEND:$end
TRANSP:OPAQUE
SUMMARY:Floating
DTSTART:$start
DTSTAMP:20150806T234327Z
SEQUENCE:0
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 60 );

    $self->assert_alarms({summary => 'Floating'});
}

sub test_floating_differenttz
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $tz = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:America/New_York
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=11
TZOFFSETFROM:-0400
TZOFFSETTO:-0500
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=2SU;BYMONTH=3
TZOFFSETFROM:-0500
TZOFFSETTO:-0400
END:DAYLIGHT
END:VTIMEZONE
END:VCALENDAR
EOF

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo', timezone => $tz});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define the event to start in a few seconds
    my $startdt = $now->clone();
    $startdt->add(DateTime::Duration->new(seconds => 2));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 15));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "95989f3d-575f-4828-9610-6f16b9d54d04";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
CREATED:20150806T234327Z
UID:574E2CD0-2D2A-4554-8B63-C7504481D3A9
DTEND:$end
TRANSP:OPAQUE
SUMMARY:Floating
DTSTART:$start
DTSTAMP:20150806T234327Z
SEQUENCE:0
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 60 );

    # no alarms
    $self->assert_alarms();

    # trigger processing a day later!
    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 86400 );

    # alarm fires
    $self->assert_alarms({summary => 'Floating', timezone => 'America/New_York', start => $start});
}

sub test_replication_at1
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    $self->assert_not_null($self->{replica});

    my $CalDAV = $self->{caldav};

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo'});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define an event that starts now and repeats hourly
    my $startdt = $now->clone();
    $startdt->add(DateTime::Duration->new(seconds => 60));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 60));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # the next event will start in a few seconds
    my $recuriddt = $startdt->clone();
    $recuriddt->add(DateTime::Duration->new(minutes => 60));
    my $recurid = $recuriddt->strftime('%Y%m%dT%H%M%S');

    # but it starts a few seconds after the regular start
    my $rstartdt = $recuriddt->clone();
    $rstartdt->add(DateTime::Duration->new(seconds => 15));
    my $recurstart = $recuriddt->strftime('%Y%m%dT%H%M%S');

    my $renddt = $rstartdt->clone();
    $renddt->add(DateTime::Duration->new(seconds => 60));
    my $recurend = $renddt->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "574E2CD0-2D2A-4554-8B63-C7504481D3A9";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.11.1//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Australia/Sydney
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4
TZOFFSETFROM:+1100
TZOFFSETTO:+1000
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10
TZOFFSETFROM:+1000
TZOFFSETTO:+1100
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
TRANSP:OPAQUE
DTEND;TZID=Australia/Sydney:$end
UID:12A08570-CF92-4418-986C-6173001AB557
DTSTAMP:20160420T141259Z
SEQUENCE:0
SUMMARY:main
DTSTART;TZID=Australia/Sydney:$start
CREATED:20160420T141217Z
RRULE:FREQ=HOURLY;INTERVAL=1;COUNT=3
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alert
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
BEGIN:VEVENT
CREATED:20160420T141217Z
UID:12A08570-CF92-4418-986C-6173001AB557
DTEND;TZID=Australia/Sydney:$recurend
TRANSP:OPAQUE
SUMMARY:exception
DTSTART;TZID=Australia/Sydney:$recurstart
DTSTAMP:20160420T141312Z
SEQUENCE:0
RECURRENCE-ID;TZID=Australia/Sydney:$recurid
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm exception
DESCRIPTION:My alarm exception has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # replicate to the other end
    $self->run_replication();

    # clean notification cache
    $self->{instance}->getnotify();

    # trigger processing of alarms
    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 500 );
    $self->assert_alarms({summary => 'main'});

    # no alarm when you run the second time
    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 500 );
    $self->assert_alarms();

    # replicate to the other end
    $self->run_replication();

    # running on the replica gets the exception, not the first instance
    $self->{replica}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 5000 );
    $self->assert_alarms({summary => 'exception'});

    # no alarm when you run the second time
    $self->{replica}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 5000 );
    $self->assert_alarms();

    # running on the master still gets the exception, because it doesn't know about the change
    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 5000 );
    $self->assert_alarms({summary => 'exception'});
}

sub test_override_double
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo'});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define an event that started almost an hour ago and repeats hourly
    my $startdt = $now->clone();
    $startdt->subtract(DateTime::Duration->new(minutes => 59, seconds => 55));
    my $start = $startdt->strftime('%Y%m%dT%H%M%S');

    my $enddt = $startdt->clone();
    $enddt->add(DateTime::Duration->new(seconds => 15));
    my $end = $enddt->strftime('%Y%m%dT%H%M%S');

    # the next event will start in a few seconds
    my $recuriddt = $now->clone();
    $recuriddt->add(DateTime::Duration->new(seconds => 5));
    my $recurid = $recuriddt->strftime('%Y%m%dT%H%M%S');

    my $rstartdt = $recuriddt->clone();
    my $recurstart = $recuriddt->strftime('%Y%m%dT%H%M%S');

    my $renddt = $rstartdt->clone();
    $renddt->add(DateTime::Duration->new(seconds => 15));
    my $recurend = $renddt->strftime('%Y%m%dT%H%M%S');

    my $lastrepl = $recuriddt->clone();
    $lastrepl->add(DateTime::Duration->new(minutes => 60));
    my $lastalarm = $lastrepl->strftime('%Y%m%dT%H%M%S');

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "574E2CD0-2D2A-4554-8B63-C7504481D3A9";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.11.1//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Australia/Sydney
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4
TZOFFSETFROM:+1100
TZOFFSETTO:+1000
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10
TZOFFSETFROM:+1000
TZOFFSETTO:+1100
END:DAYLIGHT
END:VTIMEZONE
BEGIN:VEVENT
TRANSP:OPAQUE
DTEND;TZID=Australia/Sydney:$end
UID:12A08570-CF92-4418-986C-6173001AB557
DTSTAMP:20160420T141259Z
SEQUENCE:0
SUMMARY:main
DTSTART;TZID=Australia/Sydney:$start
CREATED:20160420T141217Z
RRULE:FREQ=HOURLY;INTERVAL=1;COUNT=3
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alert
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
BEGIN:VEVENT
CREATED:20160420T141217Z
UID:12A08570-CF92-4418-986C-6173001AB557
DTEND;TZID=Australia/Sydney:$recurend
TRANSP:OPAQUE
SUMMARY:exception
DTSTART;TZID=Australia/Sydney:$recurstart
DTSTAMP:20160420T141312Z
SEQUENCE:0
RECURRENCE-ID;TZID=Australia/Sydney:$recurid
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm exception
DESCRIPTION:My alarm exception has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    # trigger processing of alarms
    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 6000 );

    $self->assert_alarms({summary => 'exception', start => $recurstart}, {summary => 'main', start => $lastalarm});
}

sub test_allday_notz
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo'});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define the event to start today
    my $startdt = $now->clone();
    $startdt->add(DateTime::Duration->new(days => 1));
    $startdt->truncate(to => 'day');
    my $start = $startdt->strftime('%Y%m%d');

    my $utc = DateTime::Format::ISO8601->new->parse_datetime($start . 'T000000Z');

    my $end = $start;

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "95989f3d-575f-4828-9610-6f16b9d54d04";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
CREATED:20150806T234327Z
UID:$uuid
DTEND;TYPE=DATE:$end
TRANSP:OPAQUE
SUMMARY:allday
DTSTART;TYPE=DATE:$start
DTSTAMP:20150806T234327Z
SEQUENCE:0
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $now->epoch() + 60 );

    $self->assert_alarms();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $utc->epoch() - 60 );

    $self->assert_alarms();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $utc->epoch() + 60 );

    $self->assert_alarms({summary => 'allday', start => $start, timezone => '[floating]'});
}

sub test_allday_sametz
{
    my ($self) = @_;
    return if not $self->{test_calalarmd};

    my $CalDAV = $self->{caldav};

    my $tz = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VTIMEZONE
TZID:Australia/Sydney
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=4
TZOFFSETFROM:+1100
TZOFFSETTO:+1000
END:STANDARD
BEGIN:DAYLIGHT
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYDAY=1SU;BYMONTH=10
TZOFFSETFROM:+1000
TZOFFSETTO:+1100
END:DAYLIGHT
END:VTIMEZONE
END:VCALENDAR
EOF

    my $CalendarId = $CalDAV->NewCalendar({name => 'foo', timezone => $tz});
    $self->assert_not_null($CalendarId);

    my $now = DateTime->now();
    $now->set_time_zone('Australia/Sydney');

    # define the event to start today
    my $startdt = $now->clone();
    $startdt->add(DateTime::Duration->new(days => 1));
    $startdt->truncate(to => 'day');
    my $start = $startdt->strftime('%Y%m%d');

    my $end = $start;

    # set the trigger to notify us at the start of the event
    my $trigger="PT0S";

    my $uuid = "95989f3d-575f-4828-9610-6f16b9d54d04";
    my $href = "$CalendarId/$uuid.ics";
    my $card = <<EOF;
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Apple Inc.//Mac OS X 10.10.4//EN
CALSCALE:GREGORIAN
BEGIN:VEVENT
CREATED:20150806T234327Z
UID:$uuid
DTEND;TYPE=DATE:$end
TRANSP:OPAQUE
SUMMARY:allday
DTSTART;TYPE=DATE:$start
DTSTAMP:20150806T234327Z
SEQUENCE:0
BEGIN:VALARM
TRIGGER:$trigger
ACTION:DISPLAY
SUMMARY: My alarm
DESCRIPTION:My alarm has triggered
END:VALARM
END:VEVENT
END:VCALENDAR
EOF

    $CalDAV->Request('PUT', $href, $card, 'Content-Type' => 'text/calendar');

    # clean notification cache
    $self->{instance}->getnotify();

    $self->{instance}->run_command({ cyrus => 1 }, 'calalarmd', '-t' => $startdt->epoch() + 60 );

    $self->assert_alarms({summary => 'allday', start => $start, timezone => 'Australia/Sydney'});
}

1;
