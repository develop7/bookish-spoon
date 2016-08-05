require 'mongoid'
require 'mongoid/geospatial'
require 'sinatra/base'
require 'aasm'
require 'json'

require 'pp'

class Task
  include Mongoid::Document
  include Mongoid::Geospatial

  field :name, type: String
  field :auth_token, type: String
  field :pickup_location, type: Point, sphere: true
  field :delivery_location, type: Point

  validates_presence_of :name, :auth_token, :pickup_location, :delivery_location

  include AASM
  field :aasm_state
  aasm do
    state :created, initial: true
    state :assigned
    state :delivered
    event :assign do
      transitions from: :created, to: :assigned
    end
    event :deliver do
      transitions from: :assigned, to: :delivered
    end
  end
end

class GeoTasksApp < Sinatra::Application
  configure do
    Mongoid.load!(File.join(__dir__, '..', 'config', 'mongoid.yml'))

    Task.create_indexes
  end

  USER_TYPES = %i(manager driver)

  # This function reads "Authentication" request header and authorizes to perform certain operation
  # @param [Symbol] type Authorization type, can be :manager or :driver
  def authorize!(type)
    raise OperationNotSupportedError.new('Unsupported authorization type') unless USER_TYPES.include?(type)

    auth = env['HTTP_AUTHENTICATION']

    halt 403, 'Use "Authentication:" header' unless auth

    # A shortcut follows: we check \if first character of +auth+ is equal to first char of +type+
    # So managers' tokens should start with 'M' and drivers' with 'D' in order to be authorized
    halt 403, 'User type mismatch' unless auth[0].downcase == type[0].downcase

    auth
  end

  post '/tasks' do
    token = authorize! :manager

    form = JSON.parse(request.body.read, symbolize_names: true)

    t = Task.new(form.merge({auth_token: token}))

    if t.valid?
      t.save

      JSON.generate({id: t.id})
    else
      JSON.generate(t.errors.to_hash(true))
    end
  end

  get '/tasks' do
    content_type 'application/x-json'
    authorize! :driver

    to_f = -> (s) { Float(s)}

    lat, lon = [params['lat'], params['lon']].map(&to_f)
    radius = params['radius'] || 10_000 # 10 km
    halt 412 unless lat && lon

    # use .collection.find, because :pickup_location.near_sphere doesn't work (requires '$geometry' parameter which
    # doesn't get serialized properly - array gets serialized to `{0: 123, 1: 234}`-like hash instead of `[123, 234]`)
    tasks = Task.collection.find(
        pickup_location: {'$nearSphere' => {
            '$geometry' => {type: 'Point', coordinates: [lat, lon]},
            '$maxDistance' => radius}},
        aasm_state: :created
    )

    tasks.to_json
  end

  post '/tasks/:id/assign' do
    content_type 'application/x-json'
    token = authorize! :driver

    t = Task.where(id: params['id'], aasm_state: :created).first

    halt 404 unless t

    t.assign
    t.auth_token = token # replace token with drivers'

    if t.save
      halt 204, 'Assigned'
    else
      halt 500
      pp t.errors
    end
  end

  post '/tasks/:id/deliver' do
    content_type 'application/x-json'
    authorize! :driver

    t = Task.where(id: params['id'], aasm_state: :assigned).first

    halt 404 unless t

    t.deliver

    if t.save
      halt 204, 'Delivered'
    else
      halt 500
      pp t.errors
    end
  end
end
