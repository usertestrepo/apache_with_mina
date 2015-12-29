require 'pry'
require 'mina/bundler'
require 'mina/rails'
require 'mina/git'
require 'mina/rbenv'
require 'mina/rvm'

# Usually mina focuses on deploying to one host and the deploy options are therefore simple.
# In our case, there is a number of possible servers to deploy to, it is therefore necessary to
# specify the host that we are targeting.
server = ENV['server']
# Since the same host can have multiple applications running in parallel, it is necessary to
# specify further which application we want to deploy
version = ENV['version']

# Set the repository (here on BitBucket)
set :repository, 'https://github.com/usertestrepo/apache_with_mina'
# setting the term_mode to system disable the "pretty-print" but prevent some other issues
set :term_mode, :system

# Manually create these paths in shared/ (eg: shared/config/database.yml) in your server.
# They will be linked in the 'deploy:link_shared_paths' step.
set :shared_paths, ['config/database.yml', 'log']

# Optional SSH settings:
# SSH forward agent to ensure that credentials are passed through for git operations
set :forward_agent, true

set :rvm_path, '/usr/local/rvm/bin/rvm'

##########################################################################
#
# Setup environment
#
##########################################################################

# This task is the environment that is loaded for most commands, such as
# `mina deploy` or `mina rake`.
task :environment do
  # Ensure that a server has been set
  unless server
    print_error "A server needs to be specified."
    exit
  end

  # Remote application folder
  set :deploy_to, "/home/rails/projects/server/#{version}"

  # Set the basic environment variables based on the server and version
  case server
  when 'qa'
    # The hostname to SSH to
    set :domain, '192.168.10.54'
    # SSH Optional settings
    set :user, 'deployer'    # Username in the server to SSH to.
    # set :port, '30000'     # SSH port number.
    # Rails environment
    set :rails_env, 'production'
  when 'prod'
    # The hostname to SSH to
    set :domain, '192.168.10.54'
    # SSH Optional settings
    set :user, 'deployer'    # Username in the server to SSH to.
    # set :port, '30000'     # SSH port number.
    # Rails environment
    set :rails_env, 'production'
  end

  # For those using RVM, use this to load an RVM version@gemset.
  invoke :'rvm:use[ruby-2.1.1@default]'
end

##########################################################################
#
# Create new host tasks
# Tasks below are related to deploying a new version of the application
#
##########################################################################

# Function extracted from http://blog.nicolai86.eu/posts/2013-05-06/syncing-database-content-down-with-mina
# allowing to read the content of the database.yml file
RYAML = <<-BASH
function ryaml {
  ruby -ryaml -e 'puts ARGV[1..-1].inject(YAML.load(File.read(ARGV[0]))) {|acc, key| acc[key] }' "$@"
};
BASH

# Execute all setup tasks defined below
desc "Create new folder structure + database.yml + DB + VirtualHost"
task :'setup:all' => :environment do
  queue! %[echo "-----> Setup folder structure on server"]
  invoke :setup
  queue! %[echo "-----> Setup the DB (create user / DB)"]
  invoke :'setup:db'
  queue! %[echo "-----> Setup Apache VirtualHost Configuration"]
  invoke :'setup:apache'
  queue! %[echo "-----> Deploy Master for this version"]
  invoke :deploy
  queue! %[echo "-----> Enable Apache host and restart Apache"]
  invoke :'apache:enable'
end

# Put any custom mkdir's in here for when `mina setup` is ran.
# For Rails apps, we'll make some of the shared paths that are shared between
# all releases.
task :setup => :environment do
  queue! %[mkdir -p "#{deploy_to}/shared/log"]
  queue! %[chmod g+rx,u+rwx "#{deploy_to}/shared/log"]

  queue! %[mkdir -p "#{deploy_to}/shared/config"]
  queue! %[chmod g+rx,u+rwx "#{deploy_to}/shared/config"]

  queue! %[touch "#{deploy_to}/shared/config/database.yml"]
  queue  %[echo "-----> Fill in information below to populate 'shared/config/database.yml'."]
  invoke :'setup:db:database_yml'
end

# Populate file database.yml with the appropriate rails_env
# Database name and user name are based on convention
# Password is defined by the user during setup
desc "Populate database.yml"
task :'setup:db:database_yml' => :environment do
  puts "Enter a name for the new database"
  db_name = STDIN.gets.chomp
  puts "Enter a user for the new database"
  db_username = STDIN.gets.chomp
  puts "Enter a password for the new database"
  db_pass = STDIN.gets.chomp
  # Virtual Host configuration file
  database_yml = <<-DATABASE.dedent
    #{rails_env}:
      adapter: sqlite3
      encoding: utf8
      database: #{db_name}
      username: #{db_username}
      password: #{db_pass}
      host: localhost
      timeout: 5000
  DATABASE
  queue! %{
    echo "-----> Populating database.yml"
    echo "#{database_yml}" > #{deploy_to!}/shared/config/database.yml
    echo "-----> Done"
  }
end

# Create the new database based on information from database.yml
# In this application DB, user is given full access to the new DB
desc "Create new database"
task :'setup:db' => :environment do
  queue! %{
    echo "-----> Import RYAML function"
    #{RYAML}
    echo "-----> Read database.yml"
    USERNAME=$(ryaml #{deploy_to!}/#{shared_path!}/config/database.yml #{rails_env} username)
    PASSWORD=$(ryaml #{deploy_to!}/#{shared_path!}/config/database.yml #{rails_env} password)
    DATABASE=$(ryaml #{deploy_to!}/#{shared_path!}/config/database.yml #{rails_env} database)
    echo "-----> Create SQL query"
    Q1="CREATE DATABASE IF NOT EXISTS $DATABASE;"
    Q2="GRANT USAGE ON *.* TO $USERNAME@localhost IDENTIFIED BY '$PASSWORD';"
    Q3="GRANT ALL PRIVILEGES ON $DATABASE.* TO $USERNAME@localhost;"
    Q4="FLUSH PRIVILEGES;"
    SQL="${Q1}${Q2}${Q3}${Q4}"
    echo "-----> Execute SQL query to create DB and user"
    echo "-----> Enter MySQL root password on prompt below"
    #{echo_cmd %[mysql -uroot -p -e "$SQL"]}
    echo "-----> Done"
  }
end

# Create a new VirtualHost file
# Server name is defined by convention
# Script executes some sudo operations
desc "Create Apache site file"
task :'setup:apache' => :environment do
  # Get variable for virtual host configuration file
  fqdn = get_fqdn(server, version)
  fqdn_ext = external_fqdn(server, version)
  # Virtual Host configuration file
  vhost = <<-HOSTFILE.dedent
    <VirtualHost *:80>
      ServerAdmin user@your-website.com
      ServerName #{get_fqdn(server, version)}
      DocumentRoot #{deploy_to!}/#{current_path!}/public
      RailsEnv production
      <Directory #{deploy_to!}/#{current_path!}/public>
        Options -MultiViews
        AllowOverride all
      </Directory>
      PassengerMinInstances 5
      # Maintenance page
      ErrorDocument 503 /503.html
      RewriteEngine On
      RewriteCond %{REQUEST_URI} !.(css|gif|jpg|png)$
      RewriteCond %{DOCUMENT_ROOT}/503.html -f
      RewriteCond %{SCRIPT_FILENAME} !503.html
      RewriteRule ^.*$ - [redirect=503,last]
    </VirtualHost>
  HOSTFILE
  queue! %{
    echo "-----> Create Temporary Apache Virtual Host"
    echo "#{vhost}" > #{fqdn}.tmp
    echo "-----> Copy Virtual Host file to /etc/apache2/sites-available/ (requires sudo)"
    #{echo_cmd %[sudo cp #{fqdn}.tmp /etc/apache2/sites-available/#{fqdn}]}
    echo "-----> Remove Temporary Apache Virtual Host"
    rm #{fqdn}.tmp
    echo "-----> Done"
  }
end

# Enable the new Virtual Host and restart Apache
desc "Enable new Apache host file"
task :'apache:enable' => :environment do
  fqdn = get_fqdn(server, version)
  queue! %{
    echo "-----> Enable Apache Virtual Host"
    #{echo_cmd %[sudo a2ensite #{fqdn}]}
    echo "-----> Remove Temporary Apache Virtual Host"
    #{echo_cmd %[sudo service apache2 reload]}
  }
end

##########################################################################
#
# Deployment related task
#
##########################################################################

desc "Deploys the current version to the server."
task :deploy => :environment do
  deploy do
    # Put things that will set up an empty directory into a fully set-up
    # instance of your project.
    invoke :'git:clone'
    invoke :'deploy:link_shared_paths'
    invoke :'bundle:install'
    # invoke :'rails:db_migrate'
    invoke :'rails:assets_precompile:force'

    to :launch do
      queue "touch #{deploy_to}/#{current_path}/tmp/restart.txt"
    end
  end
end

#########################################################################
#
# Helper functions
#
##########################################################################

#
# Get the main domain based on the server
#
# @return [String] the main domain
def main_domain(server)
  case server
  when 'qa'
    "qa-domain.com"
  when 'prod'
    "prod-domain.com"
  end
end

#
# Fully Qualified Domain Name of the host
# Concatenation of the version and the domain name
#
# @return [String] the FQDN
def get_fqdn(server, version)
  fqdn = "#{version}.#{main_domain(server)}"
  return fqdn
end

#########################################################################
#
# Libraries
#
##########################################################################

#
# See https://github.com/cespare/ruby-dedent/blob/master/lib/dedent.rb
#
class String
  def dedent
    lines = split "\n"
    return self if lines.empty?
    indents = lines.map do |line|
      line =~ /\S/ ? (line.start_with?(" ") ? line.match(/^ +/).offset(0)[1] : 0) : nil
    end
    min_indent = indents.compact.min
    return self if min_indent.zero?
    lines.map { |line| line =~ /\S/ ? line.gsub(/^ {#{min_indent}}/, "") : line }.join "\n"
  end
end