# Redmine - project management software
# Copyright (C) 2006-2011  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# Bugzilla copy utility by Matej Kenda, based on:
#   Bugzilla migration by Arjen Roodselaar, Lindix bv
#

require 'active_record'
require 'iconv'
require 'pp'

module Bugzilla
  include ApplicationHelper

  module AssignablePk
    attr_accessor :pk
    def set_pk
      self.id = self.pk unless self.pk.nil?
    end
  end

  def self.register_for_assigned_pk(klasses)
    klasses.each do |klass|
      klass.send(:include, AssignablePk)
      klass.send(:before_create, :set_pk)
    end
  end

  register_for_assigned_pk([User, Project, Issue, IssueCategory, Attachment, Version])

  # Bugzilla database settings
  # Edit for your own installation
  @@bugzilla_db_params = {
    :adapter => 'mysql',
    :database => 'bugzilla',
    :host => 'bugzilla.mysql.server',
    :port => 3306,
    :username => 'bugzilla-user',
    :password => 'bugzilla-pwd',
    :encoding => 'utf8'}

  DEFAULT_STATUS = IssueStatus.default
  CLOSED_STATUS = IssueStatus.find :first, :conditions => { :is_closed => true }
  assigned_status = IssueStatus.find_by_name("In Progress") || DEFAULT_STATUS
  resolved_status = IssueStatus.find_by_name("Resolved") || DEFAULT_STATUS
  feedback_status = IssueStatus.find_by_position("Waiting for feedback") || DEFAULT_STATUS

  STATUS_MAPPING = {
    "UNCONFIRMED" => DEFAULT_STATUS,
    "NEW" => DEFAULT_STATUS,
    "VERIFIED" => CLOSED_STATUS,
    "ASSIGNED" => assigned_status,
    "REOPENED" => assigned_status,
    "RESOLVED" => resolved_status,
    "CLOSED" => CLOSED_STATUS
  }

  DEFAULT_PRIORITY = IssuePriority.default
  immediate_prio = IssuePriority.find_by_name("Immediate") || DEFAULT_PRIORITY
  essential_prio = IssuePriority.find_by_name("Essential") || DEFAULT_PRIORITY
  important_prio = IssuePriority.find_by_name("Important") || DEFAULT_PRIORITY
  optional_prio = IssuePriority.find_by_name("Optional") || DEFAULT_PRIORITY
  low_prio = IssuePriority.find_by_name("Low") || DEFAULT_PRIORITY
  PRIORITY_MAPPING = {
    "P5" => low_prio,
    "P4" => optional_prio,
    "P3" => important_prio,
    "P2" => essential_prio,
    "P1" => immediate_prio
  }

  TRACKER_BUG = Tracker.find_by_name("Bug")
  TRACKER_FEATURE = Tracker.find_by_name("Feature")

  reporter_role = Role.find_by_position(5)
  developer_role = Role.find_by_position(4)
  manager_role = Role.find_by_position(3)
  DEFAULT_ROLE = reporter_role

  CUSTOM_FIELD_TYPE_MAPPING = {
    0 => 'string', # String
    1 => 'int',    # Numeric
    2 => 'int',    # Float
    3 => 'list',   # Enumeration
    4 => 'string', # Email
    5 => 'bool',   # Checkbox
    6 => 'list',   # List
    7 => 'list',   # Multiselection list
    8 => 'date',   # Date
  }

  RELATION_TYPE_MAPPING = {
    0 => IssueRelation::TYPE_DUPLICATES, # duplicate of
    1 => IssueRelation::TYPE_RELATES,    # related to
    2 => IssueRelation::TYPE_RELATES,    # parent of
    3 => IssueRelation::TYPE_RELATES,    # child of
    4 => IssueRelation::TYPE_DUPLICATES  # has duplicate
  }

  BUGZILLA_ID_FIELDNAME = "Bugzilla-Task"
  
  BUGZILLA_URL="http://bugzilla.my.host"
  REDMINE_URL="http://redmine.my.host"

# ---- Bugzilla database records ----
     
  class BzProfile < ActiveRecord::Base
    set_table_name :profiles
    set_primary_key :userid

    has_and_belongs_to_many :groups,
    :class_name => "BzGroup",
    :join_table => :user_group_map,
    :foreign_key => :user_id,
    :association_foreign_key => :group_id
    def login
      login_name[0..29].gsub(/[^a-zA-Z0-9_\-@\.]/, '-')
    end

    def email
      if login_name.match(/^.*@.*$/i)
        login_name
      else
        "#{login_name}@foo.bar"
      end
    end

    def lastname
      s = read_attribute(:realname)
      return 'unknown' if(s.blank?)
      return s.split(/[ ,]+/)[-1]
    end

    def firstname
      s = read_attribute(:realname)
      return 'unknown' if(s.blank?)
      return s.split(/[ ,]+/).first
    end
  end

  class BzGroup < ActiveRecord::Base
    set_table_name :groups

    has_and_belongs_to_many :profiles,
      :class_name => "BzProfile",
      :join_table => :user_group_map,
      :foreign_key => :group_id,
      :association_foreign_key => :user_id
  end

  class BzProduct < ActiveRecord::Base
    set_table_name :products

    has_many :components, :class_name => "BzComponent", :foreign_key => :product_id
    has_many :versions, :class_name => "BzVersion", :foreign_key => :product_id
    has_many :bugs, :class_name => "BzBug", :foreign_key => :product_id
  end

  class BzComponent < ActiveRecord::Base
    set_table_name :components
  end

  class BzVersion < ActiveRecord::Base
    set_table_name :versions
  end

  class BzBug < ActiveRecord::Base
    set_table_name :bugs
    set_primary_key :bug_id

    belongs_to :product, :class_name => "BzProduct", :foreign_key => :product_id
    has_many :descriptions, :class_name => "BzDescription", :foreign_key => :bug_id
    has_many :attachments, :class_name => "BzAttachment", :foreign_key => :bug_id
    has_many :cc, :class_name => "BzBugCC", :foreign_key => :bug_id
  end

  class BzBugCC < ActiveRecord::Base
    set_table_name :cc
  end

  class BzDependency < ActiveRecord::Base
    set_table_name :dependencies
  end

  class BzDuplicate < ActiveRecord::Base
    set_table_name :duplicates
  end

  class BzDescription < ActiveRecord::Base
    set_table_name :longdescs
    set_inheritance_column :bongo
    belongs_to :bug, :class_name => "BzBug", :foreign_key => :bug_id
    def eql(desc)
      self.bug_when == desc.bug_when
    end

    def === desc
      self.eql(desc)
    end

    def text
      if self.thetext.blank?
        return nil
      else
        self.thetext
      end
    end
  end

  class BzAttachment < ActiveRecord::Base
    set_table_name :attachments
    set_primary_key :attach_id

    has_one :attach_data, :class_name => 'BzAttachData', :foreign_key => :id
    def size
      return 0 if self.attach_data.nil?
      return self.attach_data.thedata.size
    end

    def original_filename
      return self.filename
    end

    def content_type
      self.mimetype
    end

    def read(*args)
      if @read_finished
        nil
      else
        @read_finished = true
        return nil if self.attach_data.nil?
        return self.attach_data.thedata
      end
    end
  end

  class BzAttachData < ActiveRecord::Base
    set_table_name :attach_data
  end

# ---- End of Bugzilla database records ----

  def self.establish_connection
    constants.each do |const|
      klass = const_get(const)
      next unless klass.respond_to? 'establish_connection'
      klass.establish_connection @@bugzilla_db_params
    end
  end
  
  def self.copy_to(proj_name, bugs)
    establish_connection

    puts
    puts " *** Copying from Bugzilla to Redmine: requested bugs #{bugs.size} ***"
    migrated = bugs_to_issues(proj_name, bugs)
    puts
    puts " *** Completed: copied bugs: #{migrated.size}/#{bugs.size} ***"
    skipped = bugs-migrated
    if skipped.empty?
      return true
    end
    puts
    puts " *** Skipped bugs: #{skipped.inspect} ***"
    return false
  end

  
private

#
# Map Bugzilla profile to Redmine user:
# 1. try to map by e-mail first
# 2. try to map by extern ID (LDAP) if available
def self.map_user(userid)
  bz_profile = BzProfile.find(userid)

  # Search e-mail in lowercase, because case might differ in both databases
  user = User.find(:first, :conditions => ["lower(mail) = ?", bz_profile.email.downcase])
  if !user && !bz_profile.extern_id.blank?
    # Not found by e-mail, try with extern id (LDAP, Active directory)
    user = User.find(:first, :conditions => ["lower(login) = ?", bz_profile.extern_id.downcase])
    if user
      puts "    User mapped by extern ID: #{bz_profile.email} -(#{user.login})-> #{user.mail}"
    end
  end
  if !user
    puts "    #{bz_profile.email} --> No appropriate Redmine user"
  end
  return user
end


#
# procedure to copy bugs from Bugzilla to a specified project in Redmine
# * Custom field BUGZILLA_ID_FIELDNAME is used to avoid the same bug to be
#   moved multiple times
# * comments are copied to issues
# * attachments are NOT copied: links to original attachments in Bugzilla
#   are inserted as comments in Redmine
# * Redmine: comment and BUGZILLA_ID_FIELDNAME are set to mark the origin
# * Bugzilla: comment and field cf_redmine_issue are set to mark destination
# * Bugzilla CC are set as watchers
# 
def self.bugs_to_issues(proj_name, bugs)
  migrated = []

  proj = Project.find_by_identifier(proj_name)
  if !proj
    print "Unknown Redmine project name: #{proj_name}"
    return migrated
  end

  mgr_role = Role.find_by_name("Manager") 
  mgrs = proj.users_by_role[mgr_role]

  if mgrs && !mgrs.empty?
    default_user = mgrs[0]
  else
    default_user = proj.principals[0]
  end

  puts " Project: #{proj.identifier}, #{proj}: #{default_user} "

  custom_field = IssueCustomField.find_by_name(BUGZILLA_ID_FIELDNAME)

  bugs.each do |b|

    bug = BzBug.find(b)
    if (bug == nil)
      puts "Unknown Bugzilla task: #{b}"
      next
    end

    description = bug.descriptions.first.text.to_s
    puts " --- Processing Bugzilla task #{bug.bug_id}: #{bug.short_desc}"

    reporter = map_user(bug.reporter)
    puts " Reporter: #{reporter}"

    bug_id_field = CustomValue.find(:first,
      :conditions => ["custom_field_id = ? and value = ?", custom_field.id, bug.id])

    if bug_id_field
      puts " Bug already migrated, skipping."
      next
    end

    author = map_user(bug.reporter) || default_user
    assigned_to =  map_user(bug.assigned_to) || author
    issue = Issue.new(
      :project => proj,
      :subject => bug.short_desc,
      :description => description || bug.short_desc,
      :author => author,
      :assigned_to => assigned_to,
      :priority => PRIORITY_MAPPING[bug.priority] || DEFAULT_PRIORITY,
      :status => STATUS_MAPPING[bug.bug_status] || DEFAULT_STATUS,
      :start_date => bug.creation_ts,
      :created_on => bug.creation_ts,
      :updated_on => bug.delta_ts
    )

    issue.tracker = bug.bug_severity == "enhancement" ? TRACKER_FEATURE : TRACKER_BUG

    #issue.category_id =  @category_map[bug.component_id] unless bug.component_id.blank?
    issue.assigned_to_id = map_user(bug.assigned_to) || default_user unless bug.assigned_to.blank?

    issue.save!
    puts " Task #{bug.id} --> Redmine issue ##{issue.id}: #{issue.status}, #{issue.priority}"

    bug.descriptions.each do |description|
      # the first comment is already added to the description field of the bug
      next if description === bug.descriptions.first
      journal = Journal.new(
        :journalized => issue,
        :user => map_user(description.who) || author,
        :notes => description.text,
        :created_on => description.bug_when
      )
      journal.save!
    end

    # Add a journal entry to capture the original bugzilla bug ID
    journal = Journal.new(
      :journalized => issue,
      :user => default_user,
      :notes => "
*Issue imported from Bugzilla.*

Original Bugzilla ID: \"Task #{bug.id}\":#{BUGZILLA_URL}/show_bug.cgi?id=#{bug.id}
"
    )
    journal.save!

    puts " Task #{bug.id}, ##{issue.id}: Migrated comments."

    bug.attachments.each do |att|
      journal = Journal.new(
      :journalized => issue,
      :user => map_user(att.submitter_id) || issue.author,
      :notes => "*Bugzilla attachment*: \"#{att.description}\":#{BUGZILLA_URL}/attachment.cgi?id=#{att.id}&action=edit",
      :created_on => att.creation_ts
      )
      journal.save!
    end

    puts " Task #{bug.id}, ##{issue.id}: Migrated attachments as links."

    # Add a comment to Bugzilla that the bug was migrated
    bz_comment = BzDescription.new(
      :bug_id => bug.id,
      :bug_when => Time.current,
      :who => bug.reporter,
      :thetext => "
*Task moved to Redmine.* #{REDMINE_URL}/issues/#{issue.id}

Please do not add comments here any more.
"
    )
    if !bz_comment.save
      puts "Can't add comment to Bugzilla."
    end
    bug.cf_redmine_issue = "#{REDMINE_URL}/issues/#{issue.id}"
    bug.save

    # Additionally save the original bugzilla bug ID as custom field value.
    issue.custom_field_values = { custom_field.id => "#{bug.id}" }
    issue.save_custom_field_values

    # Add watchers as the last step to prevent too many e-mails to be sent
    bug.cc.each do |u|
      cc_user = map_user(u.who)
      next unless cc_user
      issue.add_watcher(cc_user)
      puts " Added watcher: #{cc_user.mail}"
    end

    issue.save!

    puts " Task #{bug.id}, ##{issue.id}: Migrated CCs to watchers."
    puts ' --- Done'
    migrated << bug.id
  end
  return migrated
end

  
end #Bugzilla
