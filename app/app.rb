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
  field :location, type: Point, sphere: true

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

  # @param [Symbol] type Authorization type, can be :manager or :driver
  def authorize!(type)
    raise OperationNotSupportedError.new('Unsupported authorization type') unless USER_TYPES.include?(type)

    auth = env['HTTP_AUTHENTICATION']
    pp env

    halt 403, 'Use "Authentication:" header' unless auth

    halt 403, 'User type mismatch' unless auth[0].downcase == type[0].to_s.downcase # manager's tokens should start with 'M' and drivers' with 'D' accordingly

    auth
  end

  get '/' do
    'Hullo zeeba neiba!'
  end

  post '/tasks' do
    token = authorize!(:manager)

    form = JSON.parse(request.body.read, symbolize_names: true)

    t = Task.new(form.merge({auth_token: token}))

    if t.valid?
      t.save.to_json
    else
      pp t.errors, t
    end
  end

  get '/tasks' do
    # ze_coll.find({pickup_coord: {'$nearSphere' => {'$geometry' => {type: "Point", coordinates: [-73.93414657, 40.82302903]}, '$maxDistance' => 5 * 10_000}}})
  end
end
