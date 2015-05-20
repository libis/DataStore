ENV['RACK_ENV'] = 'test'
require 'bundler/setup'
require '../app/controllers/data_store'
require 'rspec'
require 'rack/test'

### SETUP
$http_headers =  {'HTTP_ACCEPT' => 'application/json', 'HTTP_AUTHORIZATION' => '123'}

def make_multipart(key, objekt)
  boundary = (Time.now.utc.to_f * 1000).to_i
  type = "multipart/form-data, boundary=#{boundary}"
  data = %W(--#{boundary})

  if objekt.is_a?(File)
    data << "Content-Disposition: form-data; name=\"#{key}\"; filename=\"#{File.basename(objekt.path)}\""
    data << 'Content-Transfer-Encoding: binary'
    data << 'Content-Type: application/octet-stream'
    data << ''
    data << objekt.read
  else
    data << "Content-Disposition: form-data; name=\"#{key}\""
    data << ''
    data << objekt.to_json
  end

  data << "--#{boundary}--"
  data << '' #end marker
  return type, data.flatten.join("\r\n")
end

### TESTS
describe 'Testing DataStore API' do
  include Rack::Test::Methods

  def app
    DataStore
  end

  it 'should be able to store a file' do
    objekt = File.open('./test_file.txt')
    $http_headers['CONTENT_TYPE'], data = make_multipart('data', objekt)

    post '/123', data, $http_headers

    expect(last_response).to be_ok
    $file_uuid = MultiJson.load(last_response.body)
  end

  it 'should be able to update a file' do
    $http_headers['CONTENT_TYPE'] = 'application/json'
    data = '{"data":{"object_name":"hello_world.txt", "type":"text/plain", "content":"Hello world"}}'
    put "/123/#{$file_uuid}", data, $http_headers
    expect(last_response).to be_ok

    response = MultiJson.load(last_response.body)
    expect(response['key']).to eq($file_uuid)
  end

  it 'should list the directory structure' do
    get '/123', nil, $http_headers
    expect(last_response).to be_ok

    response = MultiJson.load(last_response.body)
    r = (response.map {|m| m if m['key'].eql?($file_uuid)}).compact
    expect(r.first['key']).to eq($file_uuid)
  end

  it 'should stream the file' do
    get "/123/#{$file_uuid}",nil ,$http_headers
    expect(last_response).to be_ok
    expect(last_response.body).to eq('Hello world')
  end

  it 'should delete a file' do
    delete "/123/#{$file_uuid}",nil ,$http_headers
    expect(last_response).to be_ok
    expect(MultiJson.load(last_response.body)).to eq($file_uuid)
  end
end
