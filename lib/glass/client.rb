require 'active_support/core_ext/hash/indifferent_access'
require "google/api_client"

module Glass
  class Client
    attr_accessor :access_token,          :google_client,           :mirror_api,
                  :google_account,        :refresh_token,           :content,
                  :mirror_content_type,   :timeline_item,           :has_expired_token,
                  :api_keys,              :timeline_list
    attr_writer   :callback_url

    def self.create(timeline_item, opts={})
      client = new(opts.merge({google_account: timeline_item.google_account}))
      client.set_timeline_item(timeline_item)
      client
    end

    def initialize(opts)
      setup_google_api_keys
      initialize_google_client
      self.google_account = opts[:google_account]

      self.access_token = opts[:access_token] || google_account.try(:token)
      self.refresh_token = opts[:refresh_token] || google_account.try(:refresh_token)
      self.has_expired_token = opts[:has_expired_token] || google_account.has_expired_token?

      setup_with_our_access_tokens
      setup_with_user_access_token
      self
    end

    def get_timeline_item(id)
      response_hash(self.google_client.execute(get_timeline_item_parameters(id)).response)
    end

    def get_timeline_item_parameters(id)
      { api_method: self.mirror_api.timeline.get,
        parameters: {
          "id" => id
        }
      }
    end

    def callback_url
      if ::Rails.env.production?
        ::Rails.application.routes.url_helpers.glass_notifications_callback_url(protocol: 'https')
      else
        ::Glass::DEVELOPMENT_PROXY_URL + ::Glass.dev_callback_url + "/glass/notifications"
      end
    end





    def set_timeline_item(timeline_object)
      self.timeline_item = timeline_object
      self
    end

    def get_location(id='latest')
      response_hash(self.google_client.execute(get_location_parameters(id)).response)
    end

    def get_location_parameters(id)
      { api_method: self.mirror_api.locations.get,
        parameters: { "id" => id}
      }
    end

    def json_content(options, api_method="insert")
      if c = options[:content]
        data = c.is_a?(String) ? {text: c} : c
      else
        data = self.timeline_item.to_json.merge(options)
      end
      data = format_hash_properly(data)
      mirror_api.timeline.send(api_method).request_schema.new(data)
    end

    def text_content(text, api_method="insert")
      mirror_api.timeline.send(api_method).request_schema.new({text: text})
    end

    ## optional parameter is merged into the content hash
    ## before sending. good for specifying more application
    ## specific stuff like speakableText parameters.
    def rest_action(options, action="insert")
      body_object = json_content(options, action)
      inserting_content = { api_method: mirror_api.timeline.send(action),
                            body_object: body_object}
    end

    def get(id)
      self.google_client.execute(get_timeline_item_parameters(id))
    end

    def insert(options={})
      google_client.execute(rest_action(options, "insert"))
    end

    def patch(options={})
      glass_item_id = options.delete(:glass_item_id)
      patch_action = rest_action(options, "patch").merge(parameters: {id: glass_item_id})
      puts patch_action
      google_client.execute(patch_action)
    end

    def update(timeline_item, options={})
      glass_item_id = options.delete(:glass_item_id)
      update_content = { api_method: mirror_api.timeline.update,
                            body_object: timeline_item,
                            parameters: {id: glass_item_id}}
      google_client.execute update_content
    end

    ##
    # Gets a contact.
    #
    # @param [String] contact_id
    #   The identifier of the contact to retrieve.
    #
    # @return [Google::APIClient::Schema::Mirror::V1::Contact]
    #   The Contact that was retrieved.
    def get_contact(contact_id)
      google_client.execute(
        api_method: mirror_api.contacts.get,
        parameters: { id: contact_id }
      ).data
    end

    ##
    # Inserts a new contact.
    #
    # @param [Hash | Google::APIClient::Schema::Mirror::V1::Contact] contact
    #   The contact to insert, passed either as a hash describing its parameters
    #   or an actual Contact object created elsewhere.
    #
    # @return [Google::APIClient::Schema::Mirror::V1::Contact]
    #   The Contact that was inserted.
    def insert_contact(contact)
      method = mirror_api.contacts.insert

      if contact.kind_of?(Hash)
        contact = method.request_schema.new(contact)
      end

      google_client.execute(
          api_method: method,
          body_object: contact
      ).data
    end

    ## deprecated: please use cached_list instead
    def timeline_list(opts={as_hash: true})
      puts "DEPRECATION WARNING: timeline_list is now deprecated, please use cached_list instead"
      cached_list
    end

    def cached_list(opts={as_hash: true})
      retval = @timeline_list.nil? ? self.list(opts) : @timeline_list
      opts[:as_hash] ? retval.map(&:to_hash).map(&:with_indifferent_access) : retval
    end



    ### this method is pretty much extracted directly from
    ### the mirror API code samples in ruby
    ###
    ### https://developers.google.com/glass/v1/reference/timeline/list

    def list(opts={as_hash: true})
      page_token = nil
      parameters = {}
      self.timeline_list = []
      begin
        parameters = {}
        parameters['pageToken'] = page_token if page_token.present?
        api_result = google_client.execute(api_method: mirror_api.timeline.list,
                                           parameters: parameters)
        if api_result.success?
          timeline_items = api_result.data
          page_token = nil if timeline_items.items.empty?
          if timeline_items.items.any?
            @timeline_list.concat(timeline_items.items)
            page_token = timeline_items.next_page_token
          end
        else
          puts "An error occurred: #{result.data['error']['message']}"
          page_token = nil
        end
      end while page_token.to_s != ''
      timeline_list(opts)
    end

    def delete(options={})
      deleting_content = { api_method: mirror_api.timeline.delete,
                           parameters: options }
      google_client.execute(deleting_content)
    end

    def response_hash(google_response)
      JSON.parse(google_response.body).with_indifferent_access
    end


    private

    def setup_with_our_access_tokens
      ["client_id", "client_secret"].each do |meth|
        google_client.authorization.send("#{meth}=", self.api_keys.send(meth))
      end
    end

    def setup_with_user_access_token
      google_client.authorization.update_token!(access_token: access_token,
                                                refresh_token: refresh_token)
      update_token_if_necessary
    end

    def update_token_if_necessary
      if self.has_expired_token
        google_account.update_google_tokens(convert_user_data(google_client.authorization.fetch_access_token!))
      end
    end

    def convert_user_data(google_data_hash)
      ea_data_hash = {}
      ea_data_hash["token"] = google_data_hash["access_token"]
      ea_data_hash["expires_at"] = to_google_time(google_data_hash["expires_in"])
      ea_data_hash["id_token"] = google_data_hash["id_token"]
      ea_data_hash
    end

    def format_hash_properly(data_hash)
      data_hash.inject({}) do |acc, (key, value)|
        new_key = key.to_s.camelize(:lower)
        acc[new_key]= (new_key == "displayTime") ? format_date(value) : value
        acc
      end.with_indifferent_access
    end

    def to_google_time(time)
      Time.now.to_i + time
    end

    def format_date(time)
      time.to_time.utc.iso8601.gsub("Z", ".000Z") # fucking google has a weird format
    end

    def initialize_google_client
      application_name = ::Glass.application_name
      application_version = ::Glass.application_version
      self.google_client = ::Google::APIClient.new(application_name: application_name,
                                                   application_version: application_version)
      self.mirror_api = google_client.discovered_api("mirror", "v1")
    end

    def setup_google_api_keys
      self.api_keys = ::Glass._api_keys
    end
  end
end
