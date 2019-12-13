# name: applozic
# authors: Muhlis Budi Cahyono (muhlisbc@gmail.com)
# version: 1.0.1

enabled_site_setting :applozic_enabled

after_initialize {

  class ::Applozic
    attr_reader :connection

    def initialize
      @connection = Excon.new("https://apps.applozic.com", headers: base_headers, expects: [200])
    end

    %w(application_key authorization client_group_id).each do |s|
      define_method(s) {
        val = SiteSetting.send("applozic_#{s}")

        raise "Applozic: missing setting applozic_#{s}" if val.blank?

        val
      }
    end

    def sync_users(users)
      modify_users("add", users)

      _group_users = group_users

      if SiteSetting.applozic_enable_debugger
        Rails.logger.info("Applozic: group_users #{_group_users}")
      end

      ex_users = _group_users - users

      modify_users("remove", ex_users)

      new_users = group_users.sort

      if users.sort != new_users
        raise "Applozic: fail to sync users"
      end
    end

    def group_users
      resp_body = @connection.get(path: "/rest/ws/group/v2/info?clientGroupId=#{client_group_id}").body
      JSON.parse(resp_body)["response"]["membersId"]
    end

    def modify_users(action, users)
      if SiteSetting.applozic_enable_debugger
        Rails.logger.info("Applozic: #{action} #{users}")
      end

      if users.empty?
        return
      end

      req_body = {
        "userIds" => users,
        "clientGroupIds" => [client_group_id]
      }.to_json

      path = "/rest/ws/group/#{action}/users"

      if action == "add"
        path += "?createNew=true"
      end

      resp_body = @connection.post(path: path, body: req_body).body
      resp_json = JSON.parse(resp_body)

      if resp_json["status"] == "error"
        raise "Applozic: error #{action} users #{users}"
      end
    end

    def update_user(user)
      headers = base_headers.dup
      headers["Of-User-Id"] = user.username

      req_body = {
        "imageLink" => user.small_avatar_url
      }

      resp_body = @connection.post(path: "/rest/ws/user/update", body: req_body.to_json, headers: headers).body
      resp_json = JSON.parse(resp_body)

      if resp_json["status"] == "error"
        Rails.logger.warn("Applozic: error updating user #{user.username}")
      end
    end

    def base_headers
      {
        "Application-Key" => application_key,
        "Authorization" => "Basic #{authorization}",
        "Content-Type" => "application/json"
      }
    end
  end

  module ::Jobs
    class ApplozicSyncUsers < ::Jobs::Scheduled
      every 30.minutes

      def execute(args)
        if !SiteSetting.applozic_enabled
          return
        end

        group_name = SiteSetting.applozic_group_name
        group = Group.find_by(name: group_name)

        if group.blank?
          raise "Applozic: discourse group not found #{group_name}"
        end

        users = group.users.pluck(:username)

        Applozic.new.sync_users(users)
      end
    end

    class ApplozicUpdateUsersAvatar < ::Jobs::Scheduled
      every 1.day

      def execute(args)
        if !SiteSetting.applozic_enabled
          return
        end

        applozic  = Applozic.new
        usernames = applozic.group_users

        User.where(username: usernames).each do |user|
          applozic.update_user(user)
        end
      end
    end

    class ApplozicModifyUser < ::Jobs::Base
      def execute(args)
        Applozic.new.modify_users(args[:action], [args[:user]])
      end
    end
  end

  on(:user_added_to_group) do |user, group, _args|
    if SiteSetting.applozic_enabled && group.name == SiteSetting.applozic_group_name
      Jobs.enqueue(:applozic_modify_user, action: "add", user: user.username)
    end
  end

  on(:user_removed_from_group) do |user, group|
    if SiteSetting.applozic_enabled && group.name == SiteSetting.applozic_group_name
      Jobs.enqueue(:applozic_modify_user, action: "remove", user: user.username)
    end
  end
}
