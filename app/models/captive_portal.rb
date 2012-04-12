# This file is part of the OpenWISP Captive Portal Manager
#
# Copyright (C) 2012 OpenWISP.org
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class CaptivePortal < ActiveRecord::Base

  has_many :local_users, :dependent => :destroy
  has_many :online_users, :dependent => :destroy
  has_many :allowed_traffics, :dependent => :destroy
  has_one :radius_auth_server, :dependent => :destroy
  accepts_nested_attributes_for :radius_auth_server, :allow_destroy => true,
                                :reject_if => proc { |attributes| attributes[:host].blank? }
  has_one :radius_acct_server, :dependent => :destroy
  accepts_nested_attributes_for :radius_acct_server, :allow_destroy => true,
                                :reject_if => proc { |attributes| attributes[:host].blank? }

  # Default url to redirect clients to if session[:original_url] is not present
  DEFAULT_URL="http://rubyonrails.org/"
  # Parameter to be added to the redirection URL whenever OWMW don't return a complete URL
  OWMW_URL_PARAMETER="__owmw"

  validates_format_of :name, :with => /\A[a-zA-Z][a-zA-Z0-9\.\-]*\Z/
  validates_uniqueness_of :name
  validates_uniqueness_of :cp_interface
  validates_format_of :cp_interface, :with => /\A[a-zA-Z][a-zA-Z0-9\.\-]*\Z/
  validates_format_of :wan_interface, :with => /\A[a-zA-Z][a-zA-Z0-9\.\-]*\Z/

  validates_format_of :redirection_url, :with => /\Ahttps{0,1}:\/\/[a-zA-Z0-9:<%%>_=&\?\.\-\/\.]*\Z/
  validates_format_of :error_url, :with => /\Ahttps{0,1}:\/\/[a-zA-Z0-9:<%%>_=&\?\.\-\/\.]*\Z/

  validates_numericality_of :local_http_port, :less_than_or_equal_to => 65535, :greater_than_or_equal_to => 0
  validates_numericality_of :local_https_port, :less_than_or_equal_to => 65535, :greater_than_or_equal_to => 0

  validates_numericality_of :default_session_timeout, :greater_than_or_equal_to => 0, :allow_blank => true
  validates_numericality_of :default_idle_timeout, :greater_than_or_equal_to => 0, :allow_blank => true

  validates_numericality_of :total_download_bandwidth, :greater_than => 0, :allow_blank => true
  validates_numericality_of :total_upload_bandwidth, :greater_than => 0, :allow_blank => true
  
  validates_numericality_of :default_download_bandwidth, :greater_than => 0, :allow_blank => true
  validates_numericality_of :default_upload_bandwidth, :greater_than => 0, :allow_blank => true

  validates_presence_of :default_download_bandwidth, :unless => Proc.new { self.total_download_bandwidth.blank? }
  validates_presence_of :default_upload_bandwidth, :unless => Proc.new { self.total_upload_bandwidth.blank? }

  attr_readonly :cp_interface, :wan_interface

  before_destroy {
    worker = MiddleMan.worker(:captive_portal_worker)

    worker.remove_cp(
      :args => {
          :cp_interface => cp_interface
      }
    )
  }

  before_update {
    worker = MiddleMan.worker(:captive_portal_worker)

    # cp_interface is a readonly attribute so it wont be changed
    worker.remove_cp(
      :args => {
        :cp_interface => cp_interface
      }
    )
  }

  # Called after save on create and after "before_update" on update
  after_save {
    worker = MiddleMan.worker(:captive_portal_worker)
    
    # For some strange reasons, the following call can't be synchronous: it will
    # fail because no CaptivePortal for "cp_interface" will be found.
    # This is weird because in the after_save callback a record for 
    # "cp_interface" should exists
    worker.async_add_cp(
      :args => {
        :cp_interface => cp_interface,
        :wan_interface => wan_interface,
        :local_http_port => local_http_port,
        :local_https_port => local_https_port,
        :total_upload_bandwidth => total_upload_bandwidth,
        :total_download_bandwidth => total_download_bandwidth,
        :default_upload_bandwidth => default_upload_bandwidth,
        :default_download_bandwidth => default_download_bandwidth
      }
    )
  }

  # Initialize cache with 60 seconds of duration with memoization
  @@redirection_url_cache = Cache.new 60
  
  def compile_redirection_url(options = {})
    options[:mac_address] ||= ""
    options[:ip_address] ||= ""
    options[:original_url] ||= ""

    if (cached_url = @@redirection_url_cache["#{options[:mac_address]}-#{options[:ip_address]}"])
      cached_url
    else  
      begin
        if OWMW["url"].present? and options[:mac_address].present?
          # If OWMW is configured, get redirection URL from it.
          if (dynamic_url = AssociatedUser.site_url_by_user_mac_address(options[:mac_address]))
            if dynamic_url.match /\Ahttps{0,1}:\/\//
              url = dynamic_url
            else
              # If what we obtained from OWMW isn't an URL, add it to the default redirection URL
              # This way we can add parameters to default redirection URL
              url = redirection_url +
                  (redirection_url.include?('?') ? '&' : '?') + "#{OWMW_URL_PARAMETER}=" +
                  URI.escape(dynamic_url, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))
            end
          else
            url = redirection_url
          end
        else
          url = redirection_url
        end
      rescue Exception => e
        url = redirection_url
        Rails.logger.error "Problem compiling redirection URL: '#{e}'"
      ensure
        url.gsub!(/<%\s*MAC_ADDRESS\s*%>/, URI.escape(options[:mac_address], Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")))
        url.gsub!(/<%\s*IP_ADDRESS\s*%>/, URI.escape(options[:ip_address], Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")))
        url.gsub!(/<%\s*ORIGINAL_URL\s*%>/, URI.escape(options[:original_url], Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")))

        @@redirection_url_cache["#{options[:mac_address]}-#{options[:ip_address]}"] = url
      end
    end
  end

  def compile_error_url(options = {})
    url = error_url

    options[:mac_address] ||= ""
    options[:ip_address] ||= ""
    options[:original_url] ||= ""
    if options[:message].nil? or options[:message].blank?
      options[:message] = I18n.t(:no_message)
    end

    url.gsub!(/<%\s*MAC_ADDRESS\s*%>/, URI.escape(options[:mac_address], Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")))
    url.gsub!(/<%\s*IP_ADDRESS\s*%>/, URI.escape(options[:ip_address], Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")))
    url.gsub!(/<%\s*ORIGINAL_URL\s*%>/, URI.escape(options[:original_url], Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")))
    url.gsub!(/<%\s*MESSAGE\s*%>/, URI.escape(options[:message], Regexp.new("[^#{URI::PATTERN::UNRESERVED}]")))

    url
  end

  def authenticate_user(username, password, client_ip, client_mac)
    # TO DO: Radius request offload ... (sync for auth, async for acct)
    radius = false
    reply = Hash.new

    # Check if user is already auth'ed on with same mac address
    unless online_users.where(:username => username, :mac_address => client_mac).empty?
      return [ nil, I18n.t(:already_logged_in) ]
    end
    
    # First look in local user
    local_user = local_users.where(:username => username).first
    if !local_user.nil?
      if local_user.check_password(password)
        # Password is valid, check if the user can log in

        ## Is the user disabled?
        if local_user.disabled?
          reply[:authenticated] = false
          reply[:message] = local_user.disabled_message
        end

        ## Is the user already logged in and multiple login are not allowed for him?
        if reply[:authenticated].nil? and !local_user.allow_concurrent_login? and
            online_users.count(:conditions => {:username => username}) > 0
          reply[:authenticated] = false
          reply[:message] = I18n.t(:concurrent_login_not_allowed)
        end

        ## Is a good guy, grant him/her access
        if reply[:authenticated].nil?
          reply[:authenticated] = true
          reply[:message] = ""
          reply[:max_upload_bandwidth] = local_user.max_upload_bandwidth
          reply[:max_download_bandwidth] = local_user.max_download_bandwidth
          # TO DO: add timeouts to LocalUser model
          reply[:idle_timeout] = self.default_idle_timeout
          reply[:session_timeout] = self.default_session_timeout
        end

      else
        # Invalid password
        reply[:authenticated] = false
        reply[:message] = I18n.t(:invalid_credentials)
      end
    end

    # Then, if the user is still not auth'ed, ask a RADIUS server (if defined)
    if reply[:authenticated].nil? and !radius_auth_server.nil?
      radius = true
      reply = radius_auth_server.authenticate(
          {
              :username => username,
              :password => password,
              :ip => client_ip,
              :mac => client_mac
          }
      )
      if reply.nil?
        reply[:authenticated] = false
        reply[:message] = "RADIUS authentication internal error"
      end
    end

    if !reply[:authenticated].nil? and reply[:authenticated]
      # Access granted, add user to the online users
      online_user = online_users.build(
          :username => username,
          :password => password,
          :radius => radius,
          :ip_address => client_ip,
          :mac_address => client_mac,
          :idle_timeout => reply[:idle_timeout],
          :session_timeout => reply[:session_timeout],
          :max_upload_bandwidth => reply[:max_upload_bandwidth] || self.default_upload_bandwidth,
          :max_download_bandwidth => reply[:max_download_bandwidth] || self.default_download_bandwidth
      )
      begin
        online_user.save!
      rescue Exception => e
        return [ nil , "Cannot save user, internal error (#{e})" ]
      end

      unless self.radius_acct_server.nil?
        worker = MiddleMan.worker(:captive_portal_worker)
        worker.async_accounting_start(
            :args => {
                :acct_server_id => self.radius_acct_server.id,
                :username => online_user.username,
                :sessionid => online_user.cp_session_token,
                :ip => online_user.ip_address,
                :mac => online_user.mac_address,
                :radius => online_user.RADIUS_user?
            }
        )
      end
      [ online_user.cp_session_token, reply[:message] ]
    else
      # Login failed!
      [ nil, reply[:message] || I18n.t(:invalid_credentials) ]
    end
  end

  # The following functions are intended to be offloaded (i.e. should always be called from a worker)
  # DO NOT start a *synchronous* worker job inside the following functions!.

  def deauthenticate_user(online_user, reason)
    unless radius_acct_server.nil?
      # Use a RADIUS accounting server even if we have no RADIUS auth server
      worker = MiddleMan.worker(:captive_portal_worker)
      worker.async_accounting_stop(
          :args => {
              :acct_server_id => self.radius_acct_server.id,
              :username => online_user.username,
              :sessionid => online_user.cp_session_token,
              :ip => online_user.ip_address,
              :mac => online_user.mac_address,
              :radius => online_user.RADIUS_user?,
              :session_time => online_user.session_time_interval,
              :session_uploaded_octets => online_user.uploaded_octets,
              :session_uploaded_packets => online_user.uploaded_packets,
              :session_downloaded_octets => online_user.downloaded_octets,
              :session_downloaded_packets => online_user.downloaded_packets,
              :termination_cause => reason
          }
      )
    end
  ensure
    online_user.destroy
  end

  def deauthenticate_online_users(reason = RadiusAcctServer::SESSION_TERMINATE_CAUSE[:Forced_logout])
    self.online_users.each do |online_user|
      deauthenticate_user(online_user, reason)
    end
  end

end
