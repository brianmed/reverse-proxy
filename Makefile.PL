use ExtUtils::MakeMaker;

WriteMakefile(
  NAME => 'rhttp',
  ABSTRACT => "Reverse HTTP Proxy",
  VERSION_FROM => 'rhttp.pl',
  AUTHOR => 'Brian Medley <bpmedley@cpan.org>',
  LICENSE => 'perl',
  PREREQ_PM => {
    'JSON::PP' => '0',
    'AnyEvent' => '0',
    'IO::String' => '0',
  },
  BUILD_REQUIRES => {
    'Test::More' => '0',
  },
  test => {
    TESTS => 't/*.t',
  },
  EXE_FILES => ['rhttp.pl'],
);
