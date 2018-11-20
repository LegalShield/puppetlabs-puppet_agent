require 'spec_helper'

describe 'puppet_agent' do
  package_version = '1.2.5'
  global_params = {
    :package_version => package_version
  }
  def global_facts(facts, os)
    facts.merge(
      if os =~ /sles/
        {
          :is_pe => true,
          :operatingsystemmajrelease => facts[:operatingsystemrelease].split('.')[0],
        }
      elsif os =~ /solaris/
        {
          :is_pe => true,
        }
      elsif os =~ /windows/
        {
          :puppet_agent_appdata => 'C:\\ProgramData',
          :puppet_confdir    => 'C:\\ProgramData\\Puppetlabs\\puppet\\etc',
          :mco_confdir       => 'C:\\ProgramData\\Puppetlabs\\mcollective\\etc',
          :env_temp_variable => 'C:/tmp',
          :puppet_agent_pid  => 42,
          :puppet_config     => Puppet.version < "4.0.0" ? "file:///C:\\\\puppet.conf" : "C:\\puppet.conf",
        }
      else
        {}
      end).merge({:servername   => 'master.example.vm'})
  end

  context 'supported_operating systems' do
    on_supported_os.each do |os, facts|
      context "on #{os}" do
        let(:facts) do
          global_facts(facts, os)
        end

        if os !~ /sles/ and os !~ /solaris/
          context 'package_version is undef by default' do
            let(:facts) do
              global_facts(facts, os).merge({:is_pe => false})
            end
            it { is_expected.to contain_class('puppet_agent').with_package_version(nil) }
          end
        end

        context 'package_version is undef if pe_compiling_server_aio_build is not defined' do
          let(:facts) do
            global_facts(facts, os).merge({:is_pe => true})
          end
          it { is_expected.to contain_class('puppet_agent').with_package_version(nil) }
        end
      end
    end
  end

  context 'supported_operating systems' do
    on_supported_os.each do |os, facts|
      context "on #{os}" do
        let(:facts) do
          global_facts(facts, os).merge({:is_pe => true})
        end

        before(:each) do
          Puppet::Parser::Functions.newfunction(:pe_build_version, :type => :rvalue) {|args| '4.0.0'}
          Puppet::Parser::Functions.newfunction(:pe_compiling_server_aio_build, :type => :rvalue) {|args| '1.2.5'}
          Puppet::Parser::Functions.newfunction(:pe_compiling_server_version, :type => :rvalue) {|args| '2.2.0'}
        end

        context 'package_version is initialized automatically' do
          if Puppet.version < '4.0.0'
            it { is_expected.to contain_class('puppet_agent').with_package_version('1.2.5') }
          else
            it { is_expected.to contain_class('puppet_agent').with_package_version(nil) }
          end
        end

        context 'On a PE infrastructure node puppet_agent does nothing', :if => Puppet.version >= '4.0.0' do
          # The puppet version conditional is only required if the module supports Puppet 3.x
          before(:each) do
            facts['pe_server_version'] = '2016.2.2'
          end
          it { is_expected.to_not contain_class('puppet_agent::prepare') }
          it { is_expected.to_not contain_class('puppet_agent::install') }
        end
      end
    end
  end

  context 'supported operating systems' do
    # Due to https://github.com/mcanevet/rspec-puppet-facts/issues/68
    # Need to ensure that Windows tests are set last, otherwise puppet tries
    # to load windows providers on non-windows platforms in error.
    os_list = on_supported_os.select { |os, _x| !(os =~ /windows/) }
    windows_list = on_supported_os.select{ |os, _x| os =~ /windows/ }
    os_list.merge!(windows_list)

    os_list.each do |os, facts|
      context "on #{os}" do
        let(:facts) do
          global_facts(facts, os)
        end

        before(:each) do
          if os =~ /sles/ || os =~ /solaris/
            # Need to mock the PE functions

            Puppet::Parser::Functions.newfunction(:pe_build_version, :type => :rvalue) do |args|
              '4.0.0'
            end

            Puppet::Parser::Functions.newfunction(:pe_compiling_server_aio_build, :type => :rvalue) do |args|
              '1.2.5'
            end
          end
        end

        context 'invalid package_versions' do
          ['1.3.5banana', '1.2', '10-q-5'].each do |version|
            let(:params) { { :package_version => version } }

            it { expect { catalogue }.to raise_error(/invalid version/) }
          end
        end

        context 'valid package_versions' do
          ['1.4.0.30.g886c5ab', '1.4.0', '1.4.0-10', '1.4.0.10'].each do |version|
            let(:params) { { :package_version => version } }

            it { is_expected.to compile.with_all_deps }
            it { expect { catalogue }.not_to raise_error }
          end
        end

        [{}, {:service_names => []}].each do |params|
          context "puppet_agent class with install_options" do
            let(:params) { global_params.merge(
              {:install_options => ['OPTION1=value1','OPTION2=value2'],})
            }

            it { is_expected.to compile.with_all_deps }
            it { is_expected.to contain_class('puppet_agent::install').with_install_options(['OPTION1=value1','OPTION2=value2']) }

            unless facts[:osfamily] == 'windows'
              it { is_expected.to contain_package('puppet-agent').with_install_options(['OPTION1=value1','OPTION2=value2']) }
            end
          end
        end

        [{}, {:service_names => []}].each do |params|
          context "puppet_agent class without any parameters" do
            let(:params) { params.merge(global_params) }

            it { is_expected.to compile.with_all_deps }

            it { is_expected.to contain_class('puppet_agent') }
            it { is_expected.to contain_class('puppet_agent::params') }
            it { is_expected.to contain_class('puppet_agent::prepare') }
            it { is_expected.to contain_class('puppet_agent::install').that_requires('Class[puppet_agent::prepare]') }

            if facts[:osfamily] == 'Debian'
              deb_package_version = package_version + '-1' + facts[:lsbdistcodename]
              it { is_expected.to contain_package('puppet-agent').with_ensure(deb_package_version) }
            elsif facts[:osfamily] == 'Solaris' && (facts[:operatingsystemmajrelease] == '10' || Puppet.version < '4.0.0')
              it { is_expected.to contain_package('puppet-agent').with_ensure('present') }
            elsif facts[:osfamily] == 'windows'
              # Windows does not contain any Package resources
            else
              it { is_expected.to contain_package('puppet-agent').with_ensure(package_version) }
            end

            unless os =~ /windows/
              if Puppet.version < "4.0.0" || (os !~ /sles/ && os !~ /solaris/)
                it { is_expected.to contain_class('puppet_agent::service').that_requires('Class[puppet_agent::install]') }
              end
            end

            # Windows platform does not use Service resources
            unless facts[:osfamily] == 'windows'
              if params[:service_names].nil? &&
                !(facts[:osfamily] == 'Solaris' && facts[:operatingsystemmajrelease] == '11') &&
                (Puppet.version < "4.0.0" || os !~ /sles/)
                it { is_expected.to contain_service('puppet') }
                it { is_expected.to contain_service('mcollective') }
              else
                it { is_expected.to_not contain_service('puppet') }
                it { is_expected.to_not contain_service('mcollective') }
              end
            end
          end
        end
      end
    end
  end

  context 'unsupported operating system' do
    describe 'puppet_agent class without any parameters on Solaris/Nexenta' do
      let(:facts) {{
        :osfamily        => 'Solaris',
        :operatingsystem => 'Nexenta',
        :puppet_ssldir   => '/dev/null/ssl',
        :puppet_config   => '/dev/null/puppet.conf',
        :architecture    => 'i386',
      }}
      let(:params) { global_params }

      it { is_expected.to raise_error(Puppet::Error, /Nexenta not supported/) }
    end
  end

  context 'stringify_facts is set to true' do
    describe 'when puppet_stringify_facts evaluates as true ' do
      # Mock a supported agent but with puppet_stringify_facts set to true
      # check for both boolean true and string true
      [ true, 'true' ].each do |truthiness|
        let(:facts) {{
          :osfamily               => 'RedHat',
          :operatingsystem        => 'Fedora',
          :puppet_ssldir          => '/dev/null/ssl',
          :puppet_config          => '/dev/null/puppet.conf',
          :architecture           => 'i386',
          :puppet_stringify_facts => truthiness,
        }}
        let(:params) { global_params }

        if Puppet.version < '4.0.0'
          it { is_expected.to raise_error(Puppet::Error, /requires stringify_facts to be disabled/) }
        end
      end
    end
  end
end
