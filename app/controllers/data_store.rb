require 'sinatra/base'
require 'moneta'
require 'json'
require 'multi_json'
require 'securerandom'

class DataStore < Sinatra::Base
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

    set :metadatastore, Moneta.new(:File, dir: metadata_dir)
    set :objectdatastore, Moneta.new(:File, dir: objectdata_dir, transformer: {value: :zlib})
  end

  before do
    content_type 'application/octet-stream'
    cache_control :no_cache, :no_store
  end

  get '/?' do
    content_type :json
    #{"DataStore" => {status: Time.now}}.to_json
    build_folder_structure.to_json
  end

  get '/:folder/?' do
    content_type :json
    get_files_for_folder.to_json
  end

  post '/:folder/?' do
    data, data_content_type, data_object_name = read_parameters

    file_uuid = SecureRandom.uuid

    metadata = {created_at: Time.now,
                accessed_at: Time.now,
                content_type: data_content_type,
                object_name: data_object_name}

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

  put '/:folder/:datastore_id' do
    required_parameter :datastore_id
    file_uuid = params[:datastore_id]
    key = store_key(file_uuid)

    halt 404 unless settings.objectdatastore.key?(key)
    halt 500,"Please supply a Content-Type: application/json" unless request.env['CONTENT_TYPE'].downcase =~ /application\/json/

    data, data_content_type, data_object_name = read_parameters

    metadata = settings.metadatastore.load(key)

    nu_metadata = {accessed_at: Time.now,
                   content_type: data_content_type,
                   object_name: data_object_name}

    metadata = metadata.merge(nu_metadata)
    settings.metadatastore.store(key, metadata)
    settings.objectdatastore.store(key, data)

    content_type :json

    {key: file_uuid,
     object_name: metadata[:object_name],
     content_type: metadata[:content_type],
     created_at: metadata[:created_at],
     accessed_at: metadata[:accessed_at]
    }.to_json
  end

  get '/:folder/:datastore_id' do
    required_parameter :datastore_id
    key = store_key(params[:datastore_id])

    halt 404 unless settings.objectdatastore.key?(key)
    #metadata = settings.metadatastore.load(key)

    metadata = update_accessed_time(key)

    attachment(metadata[:object_name]) if metadata.include?(:object_name)

    content_type metadata[:content_type] || 'application/octet-stream'
    settings.objectdatastore.load(key)
  end

  delete '/:folder/:datastore_id' do

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
                        object_name: metadata[:object_name],
                        content_type: metadata[:content_type],
                        created_at: metadata[:created_at],
                        accessed_at: metadata[:accessed_at]
                       }
    end
    dir_structure
  end

  def update_accessed_time(key)
    metadata=settings.metadatastore.load(key)
    metadata[:accessed_at] = Time.now
    settings.metadatastore.store(key, metadata)
    metadata
  end

  def read_parameters
    if request.env['CONTENT_TYPE'].downcase =~ /application\/json/
      request.body.rewind
      post_params = JSON.parse(request.body.read)

      data_content_type = (post_params['data']['type'] rescue 'application/octet-stream')
      data_object_name = (post_params['data']['object_name'] rescue '')
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