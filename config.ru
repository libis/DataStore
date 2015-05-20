$LOAD_PATH << './'
require 'bundler/setup'
require 'rack/cors'
require 'rack/contrib'
require 'app/controllers/data_store'

use Rack::Cors do
  allow do
    origins '*'
    resource '*', :methods => [:post, :put], :headers => :any
  end
end

map '/store' do
  run DataStore
end