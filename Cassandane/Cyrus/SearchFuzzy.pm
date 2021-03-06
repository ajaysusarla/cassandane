#!/usr/bin/perl
#
#  Copyright (c) 2011-2017 FastMail Pty Ltd. All rights reserved.
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
#  3. The name "Fastmail Pty Ltd" must not be used to
#     endorse or promote products derived from this software without
#     prior written permission. For permission or any legal
#     details, please contact
#      FastMail Pty Ltd
#      PO Box 234
#      Collins St West 8007
#      Victoria
#      Australia
#
#  4. Redistributions of any form whatsoever must retain the following
#     acknowledgment:
#     "This product includes software developed by Fastmail Pty. Ltd."
#
#  FASTMAIL PTY LTD DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
#  INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY  AND FITNESS, IN NO
#  EVENT SHALL OPERA SOFTWARE AUSTRALIA BE LIABLE FOR ANY SPECIAL, INDIRECT
#  OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
#  USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
#  TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE
#  OF THIS SOFTWARE.
#

package Cassandane::Cyrus::SearchFuzzy;
use strict;
use warnings;
use Cwd qw(abs_path);
use DateTime;
use Data::Dumper;

use lib '.';
use base qw(Cassandane::Cyrus::TestCase);
use Cassandane::Util::Log;

sub new
{
    my ($class, @args) = @_;
    my $config = Cassandane::Config->default()->clone();
    $config->set(conversations => 'on');
    return $class->SUPER::new({ config => $config }, @args);
}

sub set_up
{
    my ($self) = @_;
    $self->SUPER::set_up();

    # This will be "words" if Xapian has a CJK word-tokeniser, "ngrams"
    # if it doesn't, or "none" if it cannot tokenise CJK at all.
    $self->{xapian_cjk_tokens} =
        $self->{instance}->{buildinfo}->get('search', 'xapian_cjk_tokens')
        || "none";

    xlog $self, "Xapian CJK tokeniser '$self->{xapian_cjk_tokens}' detected.\n";

    use experimental 'smartmatch';
    my $skipdiacrit = $self->{instance}->{config}->get('search_skipdiacrit');
    if (not defined $skipdiacrit) {
        $skipdiacrit = 1;
    }
    if ($skipdiacrit ~~ ['no', 'off', 'f', 'false', '0']) {
        $skipdiacrit = 0;
    }
    $self->{skipdiacrit} = $skipdiacrit;

    my $fuzzyalways = $self->{instance}->{config}->get('search_fuzzy_always');
    if ($fuzzyalways ~~ ['yes', 'on', 't', 'true', '1']) {
        $self->{fuzzyalways} = 1;
    } else {
        $self->{fuzzyalways} = 0 ;
    }
}

sub tear_down
{
    my ($self) = @_;
    $self->SUPER::tear_down();
}

sub create_testmessages
{
    my ($self) = @_;

    xlog $self, "Generate test messages.";
    # Some subjects with the same verb word stem
    $self->make_message("I am running") || die;
    $self->make_message("I run") || die;
    $self->make_message("He runs") || die;

    # Some bodies with the same word stems but different senders. We use
    # the "connect" word stem since it it the first example on Xapian's
    # Stemming documentation (https://xapian.org/docs/stemming.html).
    # Mails from foo@example.com...
    my %params;
    %params = (
        from => Cassandane::Address->new(
            localpart => "foo",
            domain => "example.com"
        ),
    );
    $params{'body'} ="He has connections.",
    $self->make_message("1", %params) || die;
    $params{'body'} = "Gonna get myself connected.";
    $self->make_message("2", %params) || die;
    # ...as well as from bar@example.com.
    %params = (
        from => Cassandane::Address->new(
            localpart => "bar",
            domain => "example.com"
        ),
        body => "Einstein's gravitational theory resulted in beautiful relations connecting gravitational phenomena with the geometry of space; this was an exciting idea."
    );
    $self->make_message("3", %params) || die;

    # Create the search database.
    xlog $self, "Run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');
}

sub test_copy_messages
    :needs_search_xapian
{
    my ($self) = @_;

    $self->create_testmessages();

    my $talk = $self->{store}->get_client();
    $talk->create("INBOX.foo");
    $talk->select("INBOX");
    $talk->copy("1:*", "INBOX.foo");

    xlog $self, "Run squatter again";
    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-i');
}

sub test_stem_verbs
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;
    $self->create_testmessages();

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'SEARCH for subject "runs"';
    $r = $talk->search('subject', { Quote => "runs" }) || die;
    if ($self->{fuzzyalways}) {
        $self->assert_num_equals(3, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }

    xlog $self, 'SEARCH for FUZZY subject "runs"';
    $r = $talk->search('fuzzy', ['subject', { Quote => "runs" }]) || die;
    $self->assert_num_equals(3, scalar @$r);

    xlog $self, 'XSNIPPETS for FUZZY subject "runs"';
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'subject', { Quote => 'runs' }]
    ) || die;
    $self->assert_num_equals(3, scalar @{$r->{snippets}});
}

sub test_stem_any
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;
    $self->create_testmessages();

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;

    my $r;
    xlog $self, 'SEARCH for body "connection"';
    $r = $talk->search('body', { Quote => "connection" }) || die;
    if ($self->{fuzzyalways})  {
        $self->assert_num_equals(3, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }


    xlog $self, "SEARCH for FUZZY body \"connection\"";
    $r = $talk->search(
        "fuzzy", ["body", { Quote => "connection" }],
    ) || die;
    $self->assert_num_equals(3, scalar @$r);
}

sub test_snippet_wildcard
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # Set up Xapian database
    xlog $self, "Generate and index test messages";
    my %params = (
        mime_charset => "utf-8",
    );
    my $subject;
    my $body;

    $subject = "1";
    $body = "Waiter! There's a foo in my soup!";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $subject = "2";
    $body = "Let's foop the loop.";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $term = "foo";
    xlog $self, "SEARCH for FUZZY body $term*";
    my $r = $talk->search(
        "fuzzy", ["body", { Quote => "$term*" }],
    ) || die;
    $self->assert_num_equals(2, scalar @$r);
    my $uids = $r;

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');

    xlog $self, "XSNIPPETS for $term";
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'text', { Quote => "$term*" }]
    ) || die;
    xlog $self, Dumper($r);
    $self->assert_num_equals(2, scalar @{$r->{snippets}});
}

sub test_mix_fuzzy_and_nonfuzzy
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;
    $self->create_testmessages();
    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;

    xlog $self, "SEARCH for from \"foo\@example.com\" with FUZZY body \"connection\"";
    my $r = $talk->search(
        "fuzzy", ["body", { Quote => "connection" }],
        "from", { Quote => "foo\@example.com" }
    ) || die;
    $self->assert_num_equals(2, scalar @$r);
}

sub test_weird_crasher
    :Conversations :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;
    return if not $self->{test_fuzzy_search};
    $self->create_testmessages();

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;

    xlog $self, "SEARCH for 'A 李 A'";
    my $r = $talk->xconvmultisort( [ qw(reverse arrival) ], [ 'conversations', position => [1,10] ], 'utf-8', 'fuzzy', 'text', { Quote => "A 李 A" });
    $self->assert_not_null($r);
}

sub test_stopwords
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # This test assumes that "the" is a stopword and is configured with
    # the search_stopword_path in cassandane.ini. If the option is not
    # set it tests legacy behaviour.

    my $talk = $self->{store}->get_client();

    # Set up Xapian database
    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
    );
    my $subject;
    my $body;

    $subject = "1";
    $body = "In my opinion the soup smells tasty";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $subject = "2";
    $body = "The funny thing is that this isn't funny";
    $params{body} = $body;
    $self->make_message($subject, %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    # Connect via IMAP
    xlog $self, "Select INBOX";
    $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    my $term;
    my $r;

    # Search for stopword only
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", "text", "the",
    ) || die;
    $self->assert_num_equals(2, scalar @$r);

    # Search for stopword plus significant term
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", "text", "the soup",
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    $r = $talk->search(
        "charset", "utf-8", "fuzzy", "text", "the", "fuzzy", "text", "soup",
    ) || die;
    $self->assert_num_equals(1, scalar @$r);
}

sub test_normalize_snippets
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # Set up test message with funny characters
    my $body = "foo gären советской diĝir naïve léger";
    my @terms = split / /, $body;

    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("1", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    # Assert that diacritics are matched and returned
    foreach my $term (@terms) {
        xlog $self, "XSNIPPETS for FUZZY text \"$term\"";
        $r = $talk->xsnippets(
            [['INBOX', $uidvalidity, $uids]], 'utf-8',
            ['fuzzy', 'text', { Quote => $term }]
        ) || die;
        $self->assert_num_not_equals(index($r->{snippets}[0][3], "<b>$term</b>"), -1);
    }

    # Assert that search without diacritics matches
    if ($self->{skipdiacrit}) {
        my $term = "naive";
        xlog $self, "XSNIPPETS for FUZZY text \"$term\"";
        $r = $talk->xsnippets(
            [['INBOX', $uidvalidity, $uids]], 'utf-8',
            ['fuzzy', 'text', { Quote => $term }]
        ) || die;
        $self->assert_num_not_equals(index($r->{snippets}[0][3], "<b>naïve</b>"), -1);
    }
}

sub test_skipdiacrit
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    # Set up test messages
    my $body = "Die Trauben gären.";
    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("1", %params) || die;
    $body = "Gemüse schonend garen.";
    %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("2", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'Search for "garen"';
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", ["text", { Quote => "garen" }],
    ) || die;
    if ($self->{skipdiacrit}) {
        $self->assert_num_equals(2, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }

    xlog $self, 'Search for "gären"';
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", ["text", { Quote => "gären" }],
    ) || die;
    if ($self->{skipdiacrit}) {
        $self->assert_num_equals(2, scalar @$r);
    } else {
        $self->assert_num_equals(1, scalar @$r);
    }
}

sub test_snippets_termcover
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    my $body =
    "The 'charset' portion of an 'encoded-word' specifies the character ".
    "set associated with the unencoded text.  A 'charset' can be any of ".
    "the character set names allowed in an MIME \"charset\" parameter of a ".
    "\"text/plain\" body part, or any character set name registered with ".
    "IANA for use with the MIME text/plain content-type. ".
    "".
    # Attempt to trick the snippet generator into picking the next two lines
    "Here is a line with favourite but not without that other search word ".
    "Here is another line with a favourite word but not the other one ".
    "".
    "Some character sets use code-switching techniques to switch between ".
    "\"ASCII mode\" and other modes.  If unencoded text in an 'encoded-word' ".
    "contains a sequence which causes the charset interpreter to switch ".
    "out of ASCII mode, it MUST contain additional control codes such that ".
    "ASCII mode is again selected at the end of the 'encoded-word'.  (This ".
    "rule applies separately to each 'encoded-word', including adjacent ".
    "encoded-word's within a single header field.) ".
    "When there is a possibility of using more than one character set to ".
    "represent the text in an 'encoded-word', and in the absence of ".
    "private agreements between sender and recipients of a message, it is ".
    "recommended that members of the ISO-8859-* series be used in ".
    "preference to other character sets.".
    "".
    # This is the line we want to get as a snippet
    "I don't have a favourite cereal. My favourite breakfast is oat meal.";

    xlog $self, "Generate and index test messages.";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("1", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');
    my $want = "<b>favourite</b> <b>cereal</b>";

    $r = $talk->xsnippets( [ [ 'inbox', $uidvalidity, $uids ] ],
       'utf-8', [
           'fuzzy', 'text', 'favourite',
           'fuzzy', 'text', 'cereal',
           'fuzzy', 'text', { Quote => 'bogus gnarly' }
        ]
    ) || die;
    $self->assert_num_not_equals(-1, index($r->{snippets}[0][3], $want));

    $r = $talk->xsnippets( [ [ 'inbox', $uidvalidity, $uids ] ],
       'utf-8', [
           'fuzzy', 'text', 'favourite cereal'
        ]
    ) || die;
    $self->assert_num_not_equals(-1, index($r->{snippets}[0][3], $want));

    # Regression - a phrase is treated as a loose term
    $r = $talk->xsnippets( [ [ 'INBOX', $uidvalidity, $uids ] ],
       'utf-8', [
           'fuzzy', 'text', { Quote => 'favourite nope cereal' },
           'fuzzy', 'text', { Quote => 'bogus gnarly' }
        ]
    ) || die;
    $self->assert_num_not_equals(-1, index($r->{snippets}[0][3], $want));

    $r = $talk->xsnippets( [ [ 'inbox', $uidvalidity, $uids ] ],
       'utf-8', [
           'fuzzy', 'text', { Quote => 'favourite cereal' }
        ]
    ) || die;
    $self->assert_num_not_equals(-1, index($r->{snippets}[0][3], $want));
}

sub test_cjk_words
    :min_version_3_0 :needs_search_xapian
    :needs_search_xapian_cjk_tokens(words)
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";

    my $body = "明末時已經有香港地方的概念";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("1", %params) || die;

    # Splits into the words: "み, 円, 月額, 申込
    $body = "申込み！月額円";
    %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message("2", %params) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    my $term;
    # Search for a two-character CJK word
    $term = "已經";
    xlog $self, "XSNIPPETS for FUZZY text \"$term\"";
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'text', { Quote => $term }]
    ) || die;
    $self->assert_num_not_equals(index($r->{snippets}[0][3], "<b>$term</b>"), -1);

    # Search for the CJK words 明末 and 時, note that the
    # word order is reversed to the original message
    $term = "時明末";
    xlog $self, "XSNIPPETS for FUZZY text \"$term\"";
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'text', { Quote => $term }]
    ) || die;
    $self->assert_num_equals(scalar @{$r->{snippets}}, 1);

    # Search for the partial CJK word 月
    $term = "月";
    xlog $self, "XSNIPPETS for FUZZY text \"$term\"";
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'text', { Quote => $term }]
    ) || die;
    $self->assert_num_equals(scalar @{$r->{snippets}}, 0);

    # Search for the interleaved, partial CJK word 額申
    $term = "額申";
    xlog $self, "XSNIPPETS for FUZZY text \"$term\"";
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'text', { Quote => $term }]
    ) || die;
    $self->assert_num_equals(scalar @{$r->{snippets}}, 0);

    # Search for three of four words: "み, 月額, 申込",
    # in different order than the original.
    $term = "月額み申込";
    xlog $self, "XSNIPPETS for FUZZY text \"$term\"";
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'text', { Quote => $term }]
    ) || die;
    $self->assert_num_equals(scalar @{$r->{snippets}}, 1);
}

sub test_subject_isutf8
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    # that's: "nuff réunion critères duff"
    my $subject = "=?utf-8?q?nuff_r=C3=A9union_crit=C3=A8res_duff?=";
    my $body = "empty";
    my %params = (
        mime_charset => "utf-8",
        body => $body
    );
    $self->make_message($subject, %params) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;

    # Search subject without accents
    # my $term = "réunion critères";
    my %searches;

    if ($self->{skipdiacrit}) {
        # Diacritics are stripped before indexing and search. That's a sane
        # choice as long as there is no language-specific stemming applied
        # during indexing and search.
        %searches = (
            "reunion criteres" => 1,
            "réunion critères" => 1,
            "reunion critères" => 1,
            "réunion criter" => 1,
            "réunion crit" => 0,
            "union critères" => 0,
        );
        my $term = "naive";
    } else {
        # Diacritics are not stripped from search. This currently is very
        # restrictive: until Cyrus can stem by language, this is basically
        # a whole-word match.
        %searches = (
            "reunion criteres" => 0,
            "réunion critères" => 1,
            "reunion critères" => 0,
            "réunion criter" => 0,
            "réunion crit" => 0,
            "union critères" => 0,
        );
    }

    while (my($term, $expectedCnt) = each %searches) {
        xlog $self, "SEARCH for FUZZY text \"$term\"";
        $r = $talk->search(
            "charset", "utf-8", "fuzzy", ["text", { Quote => $term }],
        ) || die;
        $self->assert_num_equals($expectedCnt, scalar @$r);
    }

}

sub test_noindex_multipartheaders
    :needs_search_xapian
{
    my ($self) = @_;

    my $talk = $self->{store}->get_client();

    my $body = ""
    . "--boundary\r\n"
    . "Content-Type: text/plain\r\n"
    . "\r\n"
    . "body"
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: application/octet-stream\r\n"
    . "Content-Transfer-Encoding: base64\r\n"
    . "\r\n"
    . "SGVsbG8sIFdvcmxkIQ=="
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: message/rfc822\r\n"
    . "\r\n"
    . "Return-Path: <bla\@local>\r\n"
    . "Mime-Version: 1.0\r\n"
    . "Content-Type: text/plain"
    . "Content-Transfer-Encoding: 7bit\r\n"
    . "Subject: baz\r\n"
    . "From: blu\@local\r\n"
    . "Message-ID: <fake.12123239947.6507\@local>\r\n"
    . "Date: Wed, 06 Oct 2016 14:59:07 +1100\r\n"
    . "To: Test User <test\@local>\r\n"
    . "\r\n"
    . "embedded"
    . "\r\n"
    . "--boundary--\r\n";

    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary",
        body => $body
    );

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $r;

    $r = $talk->search(
        "header", "Content-Type", { Quote => "multipart/mixed" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    # Don't index the headers of multiparts or embedded RFC822s
    $r = $talk->search(
        "header", "Content-Type", { Quote => "text/plain" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);
    $r = $talk->search(
        "fuzzy", "body", { Quote => "text/plain" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);
    $r = $talk->search(
        "fuzzy", "text", { Quote => "content" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);

    # But index the body of an embedded RFC822
    $r = $talk->search(
        "fuzzy", "body", { Quote => "embedded" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);
}

sub test_xattachmentname
    :needs_search_xapian
{
    my ($self) = @_;

    my $talk = $self->{store}->get_client();

    my $body = ""
    . "--boundary\r\n"
    . "Content-Type: text/plain\r\n"
    . "\r\n"
    . "body"
    . "\r\n"
    . "--boundary\r\n"
    . "Content-Type: application/x-excel; name=\"blah\"\r\n"
    . "Content-Transfer-Encoding: base64\r\n"
    . "Content-Disposition: attachment; filename=\"stuff.xls\"\r\n"
    . "\r\n"
    . "SGVsbG8sIFdvcmxkIQ=="
    . "\r\n"
    . "--boundary--\r\n";

    $self->make_message("foo",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary",
        body => $body
    );

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $r;

    $r = $talk->search(
        "fuzzy", "xattachmentname", { Quote => "stuff" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    $r = $talk->search(
        "fuzzy", "xattachmentname", { Quote => "nope" }
    ) || die;
    $self->assert_num_equals(0, scalar @$r);

    $r = $talk->search(
        "fuzzy", "text", { Quote => "stuff.xls" }
    ) || die;
    $self->assert_num_equals(1, scalar @$r);

    $r = $talk->search(
        "fuzzy", "xattachmentname", { Quote => "blah" },
    ) || die;
    $self->assert_num_equals(1, scalar @$r);
}


sub test_xapianv2
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    my $talk = $self->{store}->get_client();

    # This is a smallish regression test to check if we break something
    # obvious by moving Xapian indexing from folder:uid to message guids.
    #
    # Apart from the tests in this module, at least also the following
    # imodules are relevant: Metadata for SORT, Thread for THREAD.

    xlog $self, "Generate message";
    my $r = $self->make_message("I run", body => "Run, Forrest! Run!" ) || die;
    my $uid = $r->{attrs}->{uid};

    xlog $self, "Copy message into INBOX";
    $talk->copy($uid, "INBOX");

    xlog $self, "Run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    $r = $talk->xconvmultisort(
        [ qw(reverse arrival) ],
        [ 'conversations', position => [1,10] ],
        'utf-8', 'fuzzy', 'text', "run",
    );
    $self->assert_num_equals(2, scalar @{$r->{sort}[0]} - 1);
    $self->assert_num_equals(1, scalar @{$r->{sort}});

    xlog $self, "Create target mailbox";
    $talk->create("INBOX.target");

    xlog $self, "Copy message into INBOX.target";
    $talk->copy($uid, "INBOX.target");

    xlog $self, "Run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    $r = $talk->xconvmultisort(
        [ qw(reverse arrival) ],
        [ 'conversations', position => [1,10] ],
        'utf-8', 'fuzzy', 'text', "run",
    );
    $self->assert_num_equals(3, scalar @{$r->{sort}[0]} - 1);
    $self->assert_num_equals(1, scalar @{$r->{sort}});

    xlog $self, "Generate message";
    $self->make_message("You run", body => "A running joke" ) || die;

    xlog $self, "Run squatter";
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    $r = $talk->xconvmultisort(
        [ qw(reverse arrival) ],
        [ 'conversations', position => [1,10] ],
        'utf-8', 'fuzzy', 'text', "run",
    );
    $self->assert_num_equals(2, scalar @{$r->{sort}});

    xlog $self, "SEARCH FUZZY";
    $r = $talk->search(
        "charset", "utf-8", "fuzzy", "text", "run",
    ) || die;
    $self->assert_num_equals(3, scalar @$r);

    xlog $self, "Select INBOX";
    $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, "XSNIPPETS";
    $r = $talk->xsnippets(
        [['INBOX', $uidvalidity, $uids]], 'utf-8',
        ['fuzzy', 'body', 'run'],
    ) || die;
    $self->assert_num_equals(3, scalar @{$r->{snippets}});
}

sub test_snippets_escapehtml
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("Test1 subject with an unescaped & in it",
        mime_charset => "utf-8",
        mime_type => "text/html",
        body => "Test1 body with the same <b>tag</b> as snippets"
    ) || die;

    $self->make_message("Test2 subject with a <tag> in it",
        mime_charset => "utf-8",
        mime_type => "text/plain",
        body => "Test2 body with a <tag/>, although it's plain text",
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    # Connect to IMAP
    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');
    my %m;

    $r = $talk->xsnippets( [ [ 'inbox', $uidvalidity, $uids ] ],
       'utf-8', [ 'fuzzy', 'text', 'test1' ]
    ) || die;

    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert_str_equals("<b>Test1</b> body with the same tag as snippets", $m{body});
    $self->assert_str_equals("<b>Test1</b> subject with an unescaped &amp; in it", $m{subject});

    $r = $talk->xsnippets( [ [ 'inbox', $uidvalidity, $uids ] ],
       'utf-8', [ 'fuzzy', 'text', 'test2' ]
    ) || die;

    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert_str_equals("<b>Test2</b> body with a &lt;tag/&gt;, although it's plain text", $m{body});
    $self->assert_str_equals("<b>Test2</b> subject with a &lt;tag&gt; in it", $m{subject});
}

sub test_search_exactmatch
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("test1",
        body => "Test1 body with some long text and there is even more ".
                "and more and more and more and more and more and more ".
                "and more and more and some text and more and more and ".
                "and more and more and more and more and more and more ".
                "and almost at the end some other text that is a match ",
    ) || die;
    $self->make_message("test2",
        body => "Test2 body with some other text",
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'SEARCH for FUZZY exact match';
    my $query = '"some text"';
    $uids = $talk->search('fuzzy', 'body', $query) || die;
    $self->assert_num_equals(1, scalar @$uids);

    my %m;
    $r = $talk->xsnippets( [ [ 'inbox', $uidvalidity, $uids ] ],
       'utf-8', [ 'fuzzy', 'body', $query ]
    ) || die;

    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert(index($m{body}, "<b>some text</b>") != -1);
    $self->assert(index($m{body}, "<b>some</b> long <b>text</b>") == -1);
}

sub test_search_subjectsnippet
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("[plumbing] Re: log server v0 live",
        body => "Test1 body with some long text and there is even more ".
                "and more and more and more and more and more and more ".
                "and more and more and some text and more and more and ".
                "and more and more and more and more and more and more ".
                "and almost at the end some other text that is a match ",
    ) || die;
    $self->make_message("test2",
        body => "Test2 body with some other text",
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    xlog $self, "Select INBOX";
    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    xlog $self, 'SEARCH for FUZZY snippets';
    my $query = 'servers';
    $uids = $talk->search('fuzzy', 'text', $query) || die;
    $self->assert_num_equals(1, scalar @$uids);

    my %m;
    $r = $talk->xsnippets( [ [ 'inbox', $uidvalidity, $uids ] ],
       'utf-8', [ 'fuzzy', 'text', $query ]
    ) || die;

    %m = map { lc($_->[2]) => $_->[3] } @{ $r->{snippets} };
    $self->assert_matches(qr/^\[plumbing\]/, $m{subject});
}

sub test_audit_unindexed
    :min_version_3_1 :needs_component_jmap
{
    # This test does some sneaky things to cyrus.indexed.db to force squatter
    # report audit errors. It assumes a specific format for cyrus.indexed.db
    # and Cyrus to preserve UIDVALDITY across two consecutive APPENDs.
    # As such, it's likely to break for internal changes.

    my ($self) = @_;

    my $talk = $self->{store}->get_client();

    my $basedir = $self->{instance}->{basedir};
    my $outfile = "$basedir/audit.tmp";

    *_readfile = sub {
        open FH, '<', $outfile
            or die "Cannot open $outfile for reading: $!";
        my @entries = readline(FH);
        close FH;
        return @entries;
    };

    xlog $self, "Create message UID 1 and index it in Xapian and cyrus.indexed.db.";
    $self->make_message() || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog $self, "Create message UID 2 but *don't* index it.";
    $self->make_message() || die;

    xlog $self, "Read current cyrus.indexed.db.";
    my $result = $self->{instance}->run_command(
        {
            cyrus => 1,
            redirects => { stdout => $outfile },
        },
        'cyr_dbtool',
        "$basedir/search/c/user/cassandane/xapian/cyrus.indexed.db",
        'twoskip',
        'show'
    );
    my @entries = _readfile();
    $self->assert_num_equals(1, scalar @entries);

    xlog $self, "Add UID 2 to sequence set in cyrus.indexed.db";
    my($key, $val) = split(/\s/, $entries[0], 2);
    $val =~ s/\s+$//;
    $result = $self->{instance}->run_command(
        {
            cyrus => 1,
            handlers => {
                exited_normally => sub { return 'ok'; },
                exited_abnormally => sub { return 'failure'; },
            },
        },
        'cyr_dbtool',
        "$basedir/search/c/user/cassandane/xapian/cyrus.indexed.db",
        'twoskip',
        'set',
        $key,
        $val . ':2'
    );
    $self->assert_str_equals('ok', $result);

    xlog $self, "Run squatter audit";
    $result = $self->{instance}->run_command(
        {
            cyrus => 1,
            redirects => { stdout => $outfile },
        },
        'squatter', '-A'
    );
    my @audits = _readfile();
    $self->assert_num_equals(1, scalar @audits);
    $self->assert_str_equals("Unindexed message(s) in user.cassandane: 2 \n", $audits[0]);
}

sub test_search_omit_html
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";
    $self->make_message("toplevel",
        mime_type => "text/html",
        body => "<html><body><div>hello</div></body></html>"
    ) || die;

    $self->make_message("embedded",
        mime_type => "multipart/related",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain\r\n"
          . "\r\n"
          . "txt"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/html\r\n"
          . "\r\n"
          . "<html><body><div>world</div></body></html>"
          . "\r\n--boundary_1--\r\n"
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_num_equals(0, scalar @$uids);

    $uids = $talk->search('fuzzy', 'body', 'hello') || die;
    $self->assert_num_equals(1, scalar @$uids);

    $uids = $talk->search('fuzzy', 'body', 'world') || die;
    $self->assert_num_equals(1, scalar @$uids);
}

sub test_search_omit_ical
    :min_version_3_0 :needs_search_xapian
{
    my ($self) = @_;

    xlog $self, "Generate and index test messages.";

    $self->make_message("test",
        mime_type => "multipart/related",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain\r\n"
          . "\r\n"
          . "txt body"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/calendar;charset=utf-8\r\n"
          . "Content-Transfer-Encoding: quoted-printable\r\n"
          . "\r\n"
          . "BEGIN:VCALENDAR\r\n"
          . "VERSION:2.0\r\n"
          . "PRODID:-//CyrusIMAP.org/Cyrus 3.1.3-606//EN\r\n"
          . "CALSCALE:GREGORIAN\r\n"
          . "BEGIN:VTIMEZONE\r\n"
          . "TZID:Europe/Vienna\r\n"
          . "BEGIN:STANDARD\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n"
          . "TZOFFSETFROM:+0200\r\n"
          . "TZOFFSETTO:+0100\r\n"
          . "END:STANDARD\r\n"
          . "BEGIN:DAYLIGHT\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\n"
          . "TZOFFSETFROM:+0100\r\n"
          . "TZOFFSETTO:+0200\r\n"
          . "END:DAYLIGHT\r\n"
          . "END:VTIMEZONE\r\n"
          . "BEGIN:VEVENT\r\n"
          . "SUMMARY:icalsummary\r\n"
          . "DESCRIPTION:icaldesc\r\n"
          . "LOCATION:icallocation\r\n"
          . "CREATED:20180518T090306Z\r\n"
          . "DTEND;TZID=Europe/Vienna:20180518T100000\r\n"
          . "DTSTAMP:20180518T090306Z\r\n"
          . "DTSTART;TZID=Europe/Vienna:20180518T090000\r\n"
          . "LAST-MODIFIED:20180518T090306Z\r\n"
          . "RRULE:FREQ=DAILY\r\n"
          . "SEQUENCE:1\r\n"
          . "SUMMARY:K=C3=A4se\r\n"
          . "TRANSP:OPAQUE\r\n"
          . "UID:1234567890\r\n"
          . "END:VEVENT\r\n"
          . "END:VCALENDAR\r\n"
          . "\r\n--boundary_1--\r\n"
    ) || die;

    $self->make_message("top",
        mime_type => "text/calendar",
        body => ""
          . "BEGIN:VCALENDAR\r\n"
          . "VERSION:2.0\r\n"
          . "PRODID:-//CyrusIMAP.org/Cyrus 3.1.3-606//EN\r\n"
          . "CALSCALE:GREGORIAN\r\n"
          . "BEGIN:VTIMEZONE\r\n"
          . "TZID:Europe/Vienna\r\n"
          . "BEGIN:STANDARD\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10\r\n"
          . "TZOFFSETFROM:+0200\r\n"
          . "TZOFFSETTO:+0100\r\n"
          . "END:STANDARD\r\n"
          . "BEGIN:DAYLIGHT\r\n"
          . "DTSTART:19700101T000000\r\n"
          . "RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=3\r\n"
          . "TZOFFSETFROM:+0100\r\n"
          . "TZOFFSETTO:+0200\r\n"
          . "END:DAYLIGHT\r\n"
          . "END:VTIMEZONE\r\n"
          . "BEGIN:VEVENT\r\n"
          . "SUMMARY:icalsummary\r\n"
          . "DESCRIPTION:icaldesc\r\n"
          . "LOCATION:icallocation\r\n"
          . "CREATED:20180518T090306Z\r\n"
          . "DTEND;TZID=Europe/Vienna:20180518T100000\r\n"
          . "DTSTAMP:20180518T090306Z\r\n"
          . "DTSTART;TZID=Europe/Vienna:20180518T090000\r\n"
          . "LAST-MODIFIED:20180518T090306Z\r\n"
          . "RRULE:FREQ=DAILY\r\n"
          . "SEQUENCE:1\r\n"
          . "TRANSP:OPAQUE\r\n"
          . "UID:1234567890\r\n"
          . "END:VEVENT\r\n"
          . "END:VCALENDAR\r\n"
    ) || die;

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $r = $talk->select("INBOX") || die;
    my $uidvalidity = $talk->get_response_code('uidvalidity');
    my $uids = $talk->search('1:*', 'NOT', 'DELETED');

    $uids = $talk->search('fuzzy', 'text', 'rrule') || die;
    $self->assert_num_equals(0, scalar @$uids);

    $uids = $talk->search('fuzzy', 'subject', 'icalsummary') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'icaldesc') || die;
    $self->assert_num_equals(2, scalar @$uids);

    $uids = $talk->search('fuzzy', 'text', 'icallocation') || die;
    $self->assert_num_equals(2, scalar @$uids);
}

sub test_xapian_index_partid
    :min_version_3_0 :needs_search_xapian :needs_component_jmap
{
    my ($self) = @_;

    # UID 1: match
    $self->make_message("xtext", body => "xbody",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 2: no match
    $self->make_message("xtext", body => "xtext",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 3: no match
    $self->make_message("xbody", body => "xtext",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 4: match
    $self->make_message("nomatch", body => "xbody xtext",
        from => Cassandane::Address->new(
            localpart => "xfrom",
            domain => "example.com"
        )
    ) || die;

    # UID 5: no match
    $self->make_message("xtext", body => "xbody xtext",
        from => Cassandane::Address->new(
            localpart => "nomatch",
            domain => "example.com"
        )
    ) || die;


    $self->{instance}->run_command({cyrus => 1}, 'squatter', '-v');

    my $talk = $self->{store}->get_client();
    $talk->select("INBOX") || die;
    my $uids = $talk->search('fuzzy', 'from', 'xfrom',
                             'fuzzy', 'body', 'xbody',
                             'fuzzy', 'text', 'xtext') || die;
    $self->assert_num_equals(2, scalar @$uids);
    $self->assert_num_equals(1, @$uids[0]);
    $self->assert_num_equals(4, @$uids[1]);
}

sub test_subject_and_body_match
    :min_version_3_0 :needs_search_xapian :needs_dependency_cld2
{
    my ($self) = @_;

    $self->make_message('fwd subject', body => 'a schenectady body');

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();

    my $uids = $talk->search('fuzzy', 'text', 'fwd', 'text', 'schenectady');
    $self->assert_deep_equals([1], $uids);
}

sub test_not_match
    :min_version_3_0 :needs_search_xapian :needs_dependency_cld2
{
    my ($self) = @_;
    my $imap = $self->{store}->get_client();
    my $store = $self->{store};

    $imap->create("INBOX.A") or die;
    $store->set_folder("INBOX.A");
    $self->make_message('fwd subject', body => 'a schenectady body');
    $self->make_message('chad subject', body => 'a futz body');

    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    my $talk = $self->{store}->get_client();
    $talk->select("INBOX.A");
    my $uids = $talk->search('fuzzy', 'not', 'text', 'schenectady');
    $self->assert_deep_equals([2], $uids);
}

sub test_striphtml_alternative
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;
    my $talk = $self->{store}->get_client();

    xlog "Index message with both html and plain text part";
    $self->make_message("test",
        mime_type => "multipart/alternative",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>This is a plain text body with <b>html</b>.</div>\r\n"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/html; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>This is an html body.</div>\r\n"
          . "\r\n--boundary_1--\r\n"
    ) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert that HTML in plain text is stripped";
    my $uids = $talk->search('fuzzy', 'body', 'html') || die;
    $self->assert_deep_equals([1], $uids);

    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_deep_equals([], $uids);
}

sub test_striphtml_plain
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;
    my $talk = $self->{store}->get_client();

    xlog "Index message with only plain text part";
    $self->make_message("test",
        body => ""
          . "<div>This is a plain text body with <b>html</b>.</div>\r\n"
    ) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert that HTML in plain-text only isn't stripped";
    my $uids = $talk->search('fuzzy', 'body', 'html') || die;
    $self->assert_deep_equals([1], $uids);

    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_deep_equals([1], $uids);
}

sub test_striphtml_rfc822
    :min_version_3_3 :needs_search_xapian
{
    my ($self) = @_;
    my $talk = $self->{store}->get_client();

    xlog "Index message with attached rfc822 message";
    $self->make_message("test",
        mime_type => "multipart/mixed",
        mime_boundary => "boundary_1",
        body => ""
          . "\r\n--boundary_1\r\n"
          . "Content-Type: text/plain; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<main>plain</main>\r\n"
          . "\r\n--boundary_1\r\n"
          . "Content-Type: message/rfc822\r\n"
          . "\r\n"
          . "Subject: bar\r\n"
          . "From: from\@local\r\n"
          . "Date: Wed, 05 Oct 2016 14:59:07 +1100\r\n"
          . "To: to\@local\r\n"
          . "Mime-Version: 1.0\r\n"
          . "Content-Type: multipart/alternative; boundary=boundary_2\r\n"
          . "\r\n"
          . "\r\n--boundary_2\r\n"
          . "Content-Type: text/plain; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>embeddedplain with <b>html</b>.</div>\r\n"
          . "\r\n--boundary_2\r\n"
          . "Content-Type: text/html; charset=\"UTF-8\"\r\n"
          . "\r\n"
          . "<div>embeddedhtml.</div>\r\n"
          . "\r\n--boundary_2--\r\n"
    ) || die;
    $self->{instance}->run_command({cyrus => 1}, 'squatter');

    xlog "Assert that HTML in top-level message isn't stripped";
    my $uids = $talk->search('fuzzy', 'body', 'main') || die;
    $self->assert_deep_equals([1], $uids);

    xlog "Assert that HTML in embedded message plain text is stripped";
    $uids = $talk->search('fuzzy', 'body', 'div') || die;
    $self->assert_deep_equals([], $uids);
    $uids = $talk->search('fuzzy', 'body', 'html') || die;
    $self->assert_deep_equals([1], $uids);

}

1;
