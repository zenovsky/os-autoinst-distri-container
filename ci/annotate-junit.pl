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
my $items = qq{    <property name="openqa_job_url" value="$openqa_esc"/>\n};
$items .= qq{    <property name="gitlab_job_url" value="$gitlab_esc"/>\n} if defined $gitlab_esc;
# StepReport уже мог записать <properties> (например qase_case_id) - дополняем его, а не создаём второй блок.
unless ($xml =~ s{(<testsuite\b[^>]*>\n\s*<properties>\n)}{$1$items}s) {
    my $props = qq{  <properties>\n$items  </properties>\n};
    $xml =~ s{(<testsuite\b[^>]*>\n)}{$1$props}s or warn "annotate-junit.pl: <testsuite> tag not found in $file, properties not added\n";
}

# Ссылка в тексте failure - то, что реально видно глазами в панели деталей теста в GitLab.
my $link_line = "\n\nopenQA job: $openqa_esc";
$link_line .= "\nGitLab job: $gitlab_esc" if defined $gitlab_esc;
$xml =~ s{(<failure\b[^>]*>)(.*?)(</failure>)}{$1 . $2 . $link_line . $3}ges;

open my $out, '>:encoding(UTF-8)', $file or die "write $file: $!\n";
print $out $xml;
close $out;
