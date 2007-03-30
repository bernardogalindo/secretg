require 'digest/sha1'

class User < ActiveRecord::Base
  has_many :contexts,
           :order => 'position ASC',
           :dependent => :delete_all do
             def find_by_params(params)
               if params['url_friendly_name']
                 find_by_url_friendly_name(params['url_friendly_name'])
               elsif params['id'] && params['id'] =~ /^\d+$/
                 find(params['id'])
               elsif params['id']
                 find_by_url_friendly_name(params['id'])
               elsif params['context']
                 find_by_url_friendly_name(params['context'])
               elsif params['context_id']
                 find_by_url_friendly_name(params['context_id'])
               end
             end
           end
  has_many :projects,
           :order => 'position ASC',
           :dependent => :delete_all do
              def find_by_params(params)
                if params['url_friendly_name']
                  find_by_url_friendly_name(params['url_friendly_name'])
                elsif params['id'] && params['id'] =~ /^\d+$/
                  find(params['id'])
                elsif params['id']
                  find_by_url_friendly_name(params['id'])
                elsif params['project']
                  find_by_url_friendly_name(params['project'])
                elsif params['project_id']
                  find_by_url_friendly_name(params['project_id'])
                end
              end
              def update_positions(project_ids)
                project_ids.each_with_index do |id, position|
                  project = self.detect { |p| p.id == id.to_i }
                  raise "Project id #{id} not associated with user id #{@user.id}." if project.nil?
                  project.update_attribute(:position, position + 1)
                end
              end
              def projects_in_state_by_position(state)
                  self.sort{ |a,b| a.position <=> b.position }.select{ |p| p.state == state }
              end
              def next_from(project)
                self.offset_from(project, 1)
              end
              def previous_from(project)
                self.offset_from(project, -1)
              end
              def offset_from(project, offset)
                projects = self.projects_in_state_by_position(project.state)
                position = projects.index(project)
                return nil if position == 0 && offset < 0
                projects.at( position + offset)
              end
              def cache_note_counts
                project_note_counts = Note.count(:group => 'project_id')
                self.each do |project|
                  project.cached_note_count = project_note_counts[project.id] || 0
                end
              end
            end
  has_many :todos,
           :order => 'completed_at DESC, todos.created_at DESC',
           :dependent => :delete_all
  has_many :deferred_todos,
           :class_name => 'Todo',
           :conditions => [ 'state = ?', 'deferred' ],
           :order => 'show_from ASC, todos.created_at DESC' do
              def find_and_activate_ready
                find(:all, :conditions => ['show_from <= ?', Time.now.utc.to_date.to_time ]).collect { |t| t.activate_and_save! }
              end
           end
  has_many :completed_todos,
           :class_name => 'Todo',
           :conditions => ['todos.state = ? and todos.completed_at is not null', 'completed'],
           :order => 'todos.completed_at DESC',
           :include => [ :project, :context ] do
             def completed_within( date )
               reject { |x| x.completed_at < date }
             end

             def completed_more_than( date )
               reject { |x| x.completed_at > date }
             end
           end
  has_many :notes, :order => "created_at DESC", :dependent => :delete_all
  has_one :preference, :dependent => :destroy
  has_many :taggings
  has_many :tags, :through => :taggings, :select => "DISTINCT tags.*"
  
  attr_protected :is_admin

  validates_presence_of :login
  validates_presence_of :password, :if => :password_required?
  validates_length_of :password, :within => 5..40, :if => :password_required?
  validates_confirmation_of :password  
  validates_length_of :login, :within => 3..80
  validates_uniqueness_of :login, :on => :create
  validates_presence_of :open_id_url, :if => Proc.new{|user| user.auth_type == 'open_id'}

  def validate
    unless Tracks::Config.auth_schemes.include?(auth_type)
      errors.add("auth_type", "not a valid authentication type")
    end
  end

  alias_method :prefs, :preference

  def self.authenticate(login, pass)
    candidate = find(:first, :conditions => ["login = ?", login])
    return nil if candidate.nil?
    if candidate.auth_type == 'database'
      return candidate if candidate.password == sha1(pass)
    elsif candidate.auth_type == 'ldap' && Tracks::Config.auth_schemes.include?('ldap')
      return candidate if SimpleLdapAuthenticator.valid?(login, pass)
    end
    nil
  end
  
  def self.no_users_yet?
    count == 0
  end
  
  def self.find_admin
    find(:first, :conditions => [ "is_admin = ?", true ])    
  end
  
  def to_param
    login
  end
  
  def display_name
    if first_name.blank? && last_name.blank?
      return login
    elsif first_name.blank?
      return last_name
    elsif last_name.blank?
      return first_name
    end
    "#{first_name} #{last_name}"
  end
  
  def change_password(pass,pass_confirm)
    self.password = pass
    self.password_confirmation = pass_confirm
    save!
  end

  def crypt_word
    write_attribute("word", self.class.sha1(login + Time.now.to_i.to_s + rand.to_s))
  end
  
  def time
    prefs.tz.adjust(Time.now.utc)
  end

  def date
    time.to_date
  end

protected

  def self.sha1(pass)
    Digest::SHA1.hexdigest("#{Tracks::Config.salt}--#{pass}--")
  end

  before_create :crypt_password, :crypt_word
  before_update :crypt_password
  
  def crypt_password
    write_attribute("password", self.class.sha1(password)) if password == @password_confirmation
  end
  
  def password_required?
    auth_type == 'database'
  end
    
end