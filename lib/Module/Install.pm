# $File: //depot/cpan/Module-Install/lib/Module/Install.pm $ $Author: autrijus $
# $Revision: #54 $ $Change: 1588 $ $DateTime: 2003/06/05 06:34:26 $ vim: expandtab shiftwidth=4

package Module::Install;
$VERSION = '0.20';

die <<END unless defined $INC{'inc/Module/Install.pm'};
You must invoke Module::Install with:

    use inc::Module::Install;

not:

    use Module::Install;

END

use strict 'vars';
use File::Find;
use File::Path;

@inc::Module::Install::ISA = 'Module::Install';

=head1 NAME

Module::Install - Standalone, extensible Perl module installer

=head1 VERSION

This document describes version 0.20 of Module::Install, released
June 5, 2003.

=head1 SYNOPSIS

In your F<Makefile.PL>:

    # drop-in replacement to ExtUtils::MakeMaker!
    use inc::Module::Install;
    WriteMakefile();    # leave it empty to determine automatically

Standard usage:

    use inc::Module::Install;

    name('Your-Module');
    abstract('Some Abstract here');
    author('Your Name <email@example.com>');
    license('perl');

    include_deps('Test::More', 5.004);
    requires('Test::More');
    recommends('Acme::ComeFrom', 0.01);

    check_nmake();      # check and download nmake.exe for Win32
    &Makefile->write;

Or rename it to F<Build.PL>; just change the last line to:

    &Build->generate_makefile_pl;
    &Build->write;

You can also put all setting into F<META.yml>, and use this instead:

    use inc::Module::Install;
    &Meta->read;        # parses META.yml
    &AutoInstall->run;  # auto-install dependencies from CPAN
    &Makefile->write;   # generates Makefile
    # &Build->write;    # generates ./Build if desired

=head1 DESCRIPTION

This module provides a drop-in replacement for B<ExtUtils::MakeMaker>.
For first-time users, Brian Ingerson's I<Creating Module Distributions
with Module::Install> in June 2003 issue of The Perl Journal
(L<http://www.tpj.com/issues/>) provides a gentle introduction to how
this module works.

If you want to start working with real-world examples right away, check
out L<Module::Install-Cookbook>.  For some personal opinions behind this
module's making, see L<Module::Install-Philosophy>.

This module is designed to let module authors eliminate all duplicated
codes in F<Makefile.PL> and F<Build.PL>, by abstracting them into
I<extensions>, and distribute them under the F<inc/> directory.

To start using it, just replace the C<use ExtUtils::MakeMaker;> line
from F<Makefile.PL> with C<use inc::Module::Install;>, then run it once:

    % perl Makefile.PL
    include inc/Module/Install.pm
    include inc/Module/Install/MakeMaker.pm
    include inc/Module/Install/Base.pm
    Updating your MANIFEST file:
      Adding inc/Module/Install.pm
      Adding inc/Module/Install/Base.pm
      Adding inc/Module/Install/MakeMaker.pm

Now your distribution will have an extra F<inc/> directory, with the
minimal loader code F<inc/Module/Install.pm> copied into it.  Also,
since you made use of the C<WriteMakefile> function, the
B<Module::Install::MakeMaker> extension is also copied into F<inc/>,
along with the base extension class B<Module::Install::Base>.

End-users of your distribution do not need to install anything extra;
the distribution already includes all necessary extensions, with their
POD documentations removed.  Note that because it does not include
unused extensions or B<Module::Install> itself, the impact on
distribution size is minimized.

=head1 METHODS

=over 4

=item import(@args)

If this module was not loaded from F<inc/>, calls the C<init>
method of B<Module::Install::Admin> to include and reload itself;
see L<Module::Install::Admin/Bootstrapping> for details.

Otherwise, export a default C<AUTOLOAD> handler to the caller's package.

The C<@args> array is passed to C<new> to intialize the top-level
B<Module::Install> object; it should usually be left empty.

=cut

sub import {
    my $class = $_[0];
    my $self = $class->new(@_[1..$#_]);

    if (not -f $self->{file}) {
        require "$self->{path}/$self->{dispatch}.pm";
        mkpath "$self->{prefix}/$self->{author}";
        $self->{admin} = 
          "$self->{name}::$self->{dispatch}"->new(_top => $self);
        $self->{admin}->init;
        @_ = ($class, _self => $self);
        goto &{"$self->{name}::import"};
    }

    *{caller(0) . "::AUTOLOAD"} = $self->autoload;
}

=item autoload()

Returns an AUTOLOAD handler bound to the caller package.

=cut

sub autoload {
    my $self = shift;
    my $caller = caller;
    sub {
        ${"$caller\::AUTOLOAD"} =~ /([^:]+)$/ or die "Cannot autoload $caller";
        unshift @_, ($self, $1);
        goto &{$self->can('call')} unless uc($1) eq $1;
    };
}

=item new(%args)

Constructor, taking a hash of named arguments.  Usually you do not want
change any of them.

=cut

sub new {
    my ($class, %args) = @_;

    return $args{_self} if $args{_self};

    $args{dispatch} ||= 'Admin';
    $args{prefix}   ||= 'inc';
    $args{author}   ||= '.author';
    $args{bundle}   ||= '_bundle';

    $class =~ s/^\Q$args{prefix}\E:://;
    $args{name}     ||= $class;
    $args{version}  ||= $class->VERSION;
    unless ($args{path}) {
        $args{path}   = $args{name};
        $args{path}  =~ s!::!/!g;
    }
    $args{file}     ||= "$args{prefix}/$args{path}.pm";

    bless(\%args, $class);
}

=item call($method, @args)

Call an extension method, passing C<@args> to it.

=cut

sub call {
    my $self   = shift;
    my $method = shift;
    my $obj = $self->load($method) or return;

    unshift @_, $obj;
    goto &{$obj->can($method)};
}

=item load($method)

Include and load an extension object implementing C<$method>.

=cut

sub load {
    my ($self, $method) = @_;

    $self->load_extensions(
        "$self->{prefix}/$self->{path}", $self
    ) unless $self->{extensions};

    foreach my $obj (@{$self->{extensions}}) {
        return $obj if $obj->can($method);
    }

    my $admin = $self->{admin} or die << "END";
The '$method' method does not exist in the '$self->{prefix}' path!
Please remove the '$self->{prefix}' directory and run $0 again to load it.
END

    my $obj = $admin->load($method, 1);
    push @{$self->{extensions}}, $obj;

    $obj;
}

=item load_extensions($path, $top_obj)

Loads all extensions under C<$path>; for each extension, create a
singleton object with C<_top> pointing to C<$top_obj>, and populates the
arrayref C<$self-E<gt>{extensions}> with those objects.

=cut

sub load_extensions {
    my ($self, $path, $top_obj) = @_;

    unshift @INC, $self->{prefix}
        unless grep { $_ eq $self->{prefix} } @INC;

    local @INC = ($path, @INC);
    foreach my $rv ($self->find_extensions($path)) {
        my ($file, $pkg) = @{$rv};
        next if $self->{pathnames}{$pkg};

        eval { require $file; 1 } or (warn($@), next);
        $self->{pathnames}{$pkg} = $INC{$file};
        push @{$self->{extensions}}, $pkg->new( _top => $top_obj );
    }
}

=item load_extensions($path)

Returns an array of C<[ $file_name, $package_name ]> for each extension
module found under C<$path> and its subdirectories.

=cut

sub find_extensions {
    my ($self, $path) = @_;
    my @found;

    find(sub {
        my $file = $File::Find::name;
        return unless $file =~ m!^\Q$path\E/(.+)\.pm\Z!is;
        return if $1 eq $self->{dispatch};

        $file = "$self->{path}/$1.pm";
        my $pkg = "$self->{name}::$1"; $pkg =~ s!/!::!g;
        push @found, [$file, $pkg];
    }, $path) if -d $path;

    @found;
}

1;

__END__

=back

=head1 EXTENSIONS

All extensions belong to the B<Module::Install::*> namespace, and
inherits from B<Module::Install::Base>.  There are three kinds of them:

=over 4

=item Standard Extensions

Methods defined by a standard extension may be called as plain functions
inside F<Makefile.PL>; a corresponding object will be spawned
automatically.  Other extensions may also invoke its methods just like
their own methods:

    # delegates to $other_extension_obj->method_name(@args)
    $self->method_name(@args);

At the first time an extension's method is invoked, a POD-stripped
version of it will be included under the F<inc/Module/Install/>
directory, and becomes I<fixed> -- i.e. even if the user installs a
different version of the same extension, the included one will still be
used instead.

If you wish to upgrade extensions in F<inc/> with installed ones, simply
remove the F<inc/> directory and run C<perl Makefile.PL> again.
Alternatively, typing C<make reset> will also do this for you.

=item Private Extensions

Those extensions take the form of B<Module::Install::PRIVATE> and
B<Module::Install::PRIVATE::*>.

Authors are encouraged to put all existing F<Makefile.PL> magics into
such extensions (e.g.  F<Module::Install::PRIVATE> for common bits;
F<Module::Install::PRIVATE::DISTNAME> for functions specific to a
distribution).

Private extensions need not to be released on CPAN; simply put them
somewhere in your C<@INC>, under the C<Module/Install/> directory, and
start using their functions in F<Makefile.PL>.  Like standard
extensions, they will never be installed on the end-user's machine,
and therefore never conflict with other people's private extensions.

=item Administrative Extensions

Extensions under the B<Module::Install::Admin::*> namespace are never
included with the distribution.  Their methods are not directly
accessible from F<Makefile.PL> or other extensions; they are invoked
like this:

    # delegates to $other_admin_extension_obj->method_name(@args)
    $self->admin->method_name(@args);

These methods only take effect during the I<initialization> run, when
F<inc/> is being populated; they are ignored for end-users.  Again,
to re-initialize everything, remove the F<inc/> directory via C<make
reset> and run C<perl Makefile.PL>.

Scripts (usually one-liners stored as part of F<Makefile>) that wish to
dispatch B<AUTOLOAD> functions into administrative extensions (instead of
standard extensions) should use the B<Module::Install::Admin> module
directly.  See L<Module::Install::Admin> for details.

=back

B<Module::Install> comes with several standard extensions:

=over 4

=item Module::Install::AutoInstall

Provides C<auto_install()> to automatically fetch and install
prerequisites via B<CPANPLUS> or B<CPAN>, specified either by
the C<features> metadata or by method arguments. 

You may wish to add a C<include('ExtUtils::AutoInstall');> before
C<auto_install()> to include B<ExtUtils::AutoInstall> with your
distribution.  Otherwise, this extension will attempt to automatically
install it from CPAN.

=item Module::Install::Base

The base class of all extensions, providing C<new>, C<initialized>,
C<admin>, C<load> and the C<AUTOLOAD> dispatcher.

=item Module::Install::Build

Provides C<&Build-E<gt>write> to generate a B<Module::Build> compliant
F<Build> file, as well as other B<Module::Build> support functions.

=item Module::Install::Fetch

Handles fetching files from remote servers via FTP.

=item Module::Install::Include

Provides the C<include($pkg)> function to include pod-stripped
package(s) from C<@INC> to F<inc/>.

Also provides the C<include_deps($pkg, $base_perl_version)> function to
include every non-core modules needed by C<$pkg>, as of Perl version
C<$base_perl_version>.

=item Module::Install::Inline

Provides C<&Inline-E<gt>write> to replace B<Inline::MakeMaker>'s
functionality of making (and cleaning after) B<Inline>-based modules.

=item Module::Install::MakeMaker

Simple wrapper class for C<ExtUtils::MakeMaker::WriteMakefile>.

=item Module::Install::Makefile

Provides C<&Makefile-E<gt>write> to generate a B<ExtUtils::MakeMaker>
compliant F<Makefile>; preferred over B<Module::Install::MakeMaker>.
It adds several extra C<make> targets, as well as being more intelligent
at guessing unspecified arguments.

=item Module::Install::Makefile::Name

Guess the distribution name.

=item Module::Install::Makefile::Version

Guess the distribution version.

=item Module::Install::Metadata

Provides C<&Meta-E<gt>write> to generate a B<YAML>-compliant F<META.yml>
file, and C<&Meta-E<gt>read> to parse it for C<&Makefile>, C<&Build> and
C<&AutoInstall> to use.

=item Module::Install::PAR

Makes pre-compiled module binary packages from F<blib>, and download
existing ones to save the user from recompiling.

=item Module::Install::Run

Determines if a command is available on the user's machine, and run
external commands via B<IPC::Run3>.

=item Module::Install::Scripts

Handles packaging and installation of scripts, instead of modules.

=item Module::Install::Win32

Functions related for installing modules on Win32, e.g. automatically
fetching and installing F<nmake.exe> for users that need it.

=back

B<Module::Install> also comes with several administrative extensions:

=over

=item Module::Install::Admin::Find

Functions for finding extensions, installed packages and files in
subdirectories.

=item Module::Install::Admin::Manifest

Functions for manipulating and updating the F<MANIFEST> file.

=item Module::Install::Admin::Metadata

Functions for manipulating and updating the F<META.yml> file.

=item Module::Install::Admin::ScanDeps

Handles scanning for non-core dependencies via B<Module::ScanDeps> and
B<Module::CoreList>.

=back

Please consult their own POD documentations for detailed information.

=head1 FAQ

=head2 What are the benefits of using B<Module::Install>?

Here is a brief overview of the reasons:

    Does everything ExtUtils::MakeMaker does.
    Requires no installation for end-users.
    Generate stock Makefile.PL for Module::Build users.
    Guaranteed forward-compatibility.
    Automatically updates your MANIFEST.
    Distributing scripts is easy.
    Include prerequisite modules (even the entire dependency tree).
    Auto-installation of prerequisites.
    Support for Inline-based modules.
    Support for precompiled PAR binaries.

Besides, if you author more than one CPAN modules, chances are there
are duplications in their F<Makefile.PL>, and also with other CPAN module
you copied the code from.  B<Module::Install> makes it really easy for you
to abstract away such codes; see the next question.

=head2 How is this different from its predecessor, B<CPAN::MakeMaker>?

According to Brian Ingerson, the author of B<CPAN::MakeMaker>,
their difference is that I<Module::Install is sane>.

Also, this module is not self-modifying, and offers a clear separation
between standard, private and administrative extensions.  Therefore
writing extensions for B<Module::Install> is easier -- instead of
tweaking your local copy of C<CPAN/MakeMaker.pm>, just make your own
B<Modula::Install::PRIVATE> module, or a new B<Module::Install::*>
extension.

=head1 SEE ALSO

L<Module::Install-Cookbook>,
L<Module::Install-Philosophy>,
L<inc::Module::Install>

L<Module::Install::AutoInstall>,
L<Module::Install::Base>,
L<Module::Install::Build>,
L<Module::Install::Directives>,
L<Module::Install::Fetch>,
L<Module::Install::Include>,
L<Module::Install::MakeMaker>,
L<Module::Install::Makefile>,
L<Module::Install::Makefile::CleanFiles>,
L<Module::Install::Makefile::Name>,
L<Module::Install::Makefile::Version>,
L<Module::Install::Metadata>,
L<Module::Install::PAR>,
L<Module::Install::Run>,
L<Module::Install::Scripts>,
L<Module::Install::Win32>

L<Module::Install::Admin>,
L<Module::Install::Admin::Find>,
L<Module::Install::Admin::Manifest>,
L<Module::Install::Admin::Metadata>,
L<Module::Install::Admin::ScanDeps>

L<CPAN::MakeMaker>,
L<Inline::MakeMaker>,
L<ExtUtils::MakeMaker>,
L<Module::Build>

=head1 AUTHORS

Brian Ingerson E<lt>INGY@cpan.orgE<gt>,
Autrijus Tang E<lt>autrijus@autrijus.orgE<gt>

=head1 COPYRIGHT

Copyright 2003 by Autrijus Tang E<lt>autrijus@autrijus.orgE<gt>,
Brian Ingerson E<lt>INGY@cpan.orgE<gt>.

Copyright 2002 by Brian Ingerson E<lt>INGY@cpan.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
