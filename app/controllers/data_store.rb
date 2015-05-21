require 'sinatra/base'
require 'sinatra/config_file'
require 'moneta'
require 'json'
require 'multi_json'
require 'securerandom'
require 'date'

class DataStore < Sinatra::Base
  register Sinatra::ConfigFile


  configure do
    set :root, File.absolute_path("#{File.dirname(__FILE__)}/../../")
    set :method_override, true # make a PUT, DELETE possible with the _method parameter
    set :show_exceptions, false
    set :raise_errors, false
    set :views, Proc.new { "#{root}/app/views" }
    set :logging, true
    set :static, true

    set :metadata_dir, "#{root}/data/metadata"
    set :objectdata_dir, "#{root}/data/objects"

    set :metadatastore, Moneta.new(:File, dir: metadata_dir, serializer: :json)
    set :objectdatastore, Moneta.new(:File, dir: objectdata_dir, transformer: {value: :zlib})

    config_file "config/config.yml"
  end

  before do
    content_type 'application/octet-stream'
    cache_control :no_cache, :no_store
  end

  #Get all Folders
  get '/?' do
    content_type :json
    build_folder_structure.to_json
  end

  #Get all objects for a folder
  get '/:folder/?' do
    content_type :json
    get_files_for_folder.to_json
  end

  #Save an object to the folder
  post '/:folder/?' do
    allowed_to_write
    data, data_content_type, data_object_name = read_parameters

    file_uuid = SecureRandom.uuid

    metadata = {created_at: Time.now,
                accessed_at: Time.now,
                content_type: data_content_type,
                name: data_object_name}

    key = store_key(file_uuid)

    settings.metadatastore.store(key, metadata)

    if data.is_a?(Tempfile)
      settings.objectdatastore.store(key, data.read)
    else
      settings.objectdatastore.store(key, data)
    end

    content_type :json
    file_uuid.to_json
  end

  #Update an object in a folder
  put '/:folder/:datastore_id' do
    allowed_to_write
    required_parameter :datastore_id
    file_uuid = params[:datastore_id]
    key = store_key(file_uuid)

    halt 404 unless settings.objectdatastore.key?(key)
    halt 500,"Please supply a Content-Type: application/json" unless request.env['CONTENT_TYPE'].downcase =~ /application\/json/

    data, data_content_type, data_object_name = read_parameters

    metadata = settings.metadatastore.load(key)

    nu_metadata = {'accessed_at' => Time.now,
                   'content_type' => data_content_type,
                   'name' => data_object_name}

    metadata = metadata.merge(nu_metadata)
    settings.metadatastore.store(key, metadata)
    settings.objectdatastore.store(key, data)

    content_type :json

    {key: file_uuid,
     name: metadata['name'] || '',
     content_type: metadata['content_type'] || 'application/octet-stream',
     created_at: metadata['created_at'] || '',
     accessed_at: metadata['accessed_at'] || ''
    }.to_json
  end

  #Stream Object in folder
  get '/:folder/:datastore_id' do
    required_parameter :datastore_id
    key = store_key(params[:datastore_id])

    halt 404 unless settings.objectdatastore.key?(key)
    #metadata = settings.metadatastore.load(key)

    metadata = update_accessed_time(key)

    attachment(metadata['name']) if metadata.include?('name')

    content_type metadata['content_type'] || 'application/octet-stream'
    settings.objectdatastore.load(key)
  end

  #Delete an object from a folder
  delete '/:folder/:datastore_id' do
    allowed_to_write
    required_parameter :datastore_id
    key = store_key(params[:datastore_id])

    settings.metadatastore.delete(key)
    settings.objectdatastore.delete(key)

    content_type :json
    params[:datastore_id].to_json

  end

  not_found do
    content_type :json
    message = body.join("\n")
    logger.error(message)
    message.to_json
  end

  error do
    content_type :json
    message = env['sinatra.error'].to_s
    logger.error(message)
    message.to_json
  end

  private
  def allowed_to_write
    halt 500, 'Please supply an API KEY' unless request.env.include?('HTTP_AUTHORIZATION') || params.include?('api_key')
    api_key = request.env['HTTP_AUTHORIZATION'] || params['api_key']
    api_key = api_key =~ /^DataStore/ ? api_key.split('DataStore').last.strip : api_key
    api_key_data = settings.keys[api_key] || nil

    halt 401, "API KEY found incorrect" unless api_key_data
    halt 401, "API KEY inactive" if DateTime.now < api_key_data[:start_date] || DateTime.now > api_key_data[:end_date]
  end


  def folder
    folder_from_query || (halt 404, 'No folder found')
  end

  def folder_from_query
    return nil unless params.include?('folder')
    params[:folder]
  end

  def required_parameter(param)
    if param.is_a?(Array)
      halt 400, "Missing parameter: one of #{param.join(', ')} is needed" if (param.map(&:to_s) & params.keys.map(&:to_s)).empty?
    else
      halt 400, "Missing #{param.to_s} parameter" unless params.keys.map(&:to_s).include?(param.to_s)
    end
  end

  def store_key(key)
    halt 404, 'No folder found' unless folder
    "#{folder}__#{key}"
  end

  def build_folder_structure
    folders = []
    Dir.glob("#{settings.metadata_dir}/*__*").each do |metadata_path|
      key = File.basename(metadata_path)
      folders << key.split('__')[0]
    end
    folders.uniq.sort
  end
  
  def get_files_for_folder
    #TODO: do some caching
    dir_structure = []
    Dir.glob("#{settings.metadata_dir}/#{folder}__*").each do |metadata_path|

      key = File.basename(metadata_path)
      metadata = settings.metadatastore.load(key)

      dir_structure << {key: key.split('__')[1],
                        name: metadata['name'] || '',
                        content_type: metadata['content_type'] || 'application/octet-stream',
                        created_at: metadata['created_at'] || '',
                        accessed_at: metadata['accessed_at'] || ''
                       }
    end
    dir_structure
  end

  def update_accessed_time(key)
    metadata=settings.metadatastore.load(key)
    metadata['accessed_at'] = Time.now
    settings.metadatastore.store(key, metadata)
    metadata
  end

  def read_parameters
    if request.env['CONTENT_TYPE'].downcase =~ /application\/json/
      request.body.rewind
      post_params = JSON.parse(request.body.read)

      data_content_type = (post_params['data']['type'] rescue 'application/octet-stream')
      data_object_name = (post_params['data']['name'] rescue '')
      data = post_params['data']['content'] rescue nil
    else
      data_content_type = (params[:data][:type] rescue 'application/octet-stream')
      data_object_name = (params[:data][:filename] rescue '')
      data = params[:data][:tempfile] rescue nil
    end

    halt 404, 'No data found.' if data.nil?

    return data, data_content_type, data_object_name
  end

end