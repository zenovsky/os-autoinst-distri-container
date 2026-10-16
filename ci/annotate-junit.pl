#!/usr/bin/env perl
# Добавляет в скачанный JUnit-отчёт ссылку(и) на job (openQA, и опционально GitLab), чтобы
# при просмотре во вкладке Tests можно было сразу перейти к видео/скриншотам/логам job'а,
# из которого получился этот отчёт. Делается здесь, а не в StepReport.pm, потому что именно
# run-openqa-tests.sh знает реальный id job'а и URL openQA в момент скачивания файла.
use strict;
use warnings;

my ($file, $openqa_url, $gitlab_url) = @ARGV;
die "usage: annotate-junit.pl <file.xml> <openqa_job_url> [gitlab_job_url]\n"
  unless defined $file && defined $openqa_url && length $openqa_url;

sub xml_escape {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

open my $fh, '<:encoding(UTF-8)', $file or die "open $file: $!\n";
local $/;
my $xml = <$fh>;
close $fh;

my $openqa_esc = xml_escape($openqa_url);
my $gitlab_esc = defined $gitlab_url && length $gitlab_url ? xml_escape($gitlab_url) : undef;

# <properties> - для машинной обработки (другие тулы, будущий конвертер в Allure и т.п.).
my $props = qq{  <properties>\n    <property name="openqa_job_url" value="$openqa_esc"/>\n};
$props .= qq{    <property name="gitlab_job_url" value="$gitlab_esc"/>\n} if defined $gitlab_esc;
$props .= qq{  </properties>\n};
$xml =~ s{(<testsuite\b[^>]*>\n)}{$1$props}s
  or warn "annotate-junit.pl: <testsuite> tag not found in $file, properties not added\n";

my $link_text = "openQA job: $openqa_esc";
$link_text .= "\nGitLab job: $gitlab_esc" if defined $gitlab_esc;

$xml =~ s{(<failure\b[^>]*>)(.*?)(</failure>)}{$1 . $2 . "\n\n$link_text" . $3}ges;
$xml =~ s{(<system-out>)(.*?)(</system-out>)}{$1$2\n\n$link_text$3}gs;
$xml =~ s{<testcase\b([^>]*?)\s*/>}{<testcase$1>\n    <system-out>$link_text</system-out>\n  </testcase>}g;

open my $out, '>:encoding(UTF-8)', $file or die "write $file: $!\n";
print $out $xml;
close $out;
