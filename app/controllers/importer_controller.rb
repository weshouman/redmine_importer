require 'csv'
require 'tempfile'

class MultipleIssuesForUniqueValue < Exception
end

class NoIssueForUniqueValue < Exception
end

Journal.class_exec do
  def empty?
    (details.empty? && notes.blank?)
  end
end

class ImporterController < ApplicationController
  before_action :find_project

  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
    :author, :description, :category, :priority, :tracker, :status,
    :start_date, :due_date, :done_ratio, :estimated_hours,
    :parent_issue, :watchers ]
  
  def index
  end

  def match
    # Delete existing iip to ensure there can't be two iips for a user
    ImportInProgress.delete_all(["user_id = ?",User.current.id])
    # save import-in-progress data
    iip = ImportInProgress.where( :user_id => User.current.id).first_or_create
    iip.quote_char = params[:wrapper]
    iip.col_sep = params[:splitter]
    iip.encoding = params[:encoding]
    iip.created = Time.new

    unless params[:file]
      flash[:error] = 'You must provide a file !'

      redirect_to importer_index_path(:project_id => @project)
      return
    end
    iip.csv_data = params[:file].read
    iip.save
    
    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime("%Y-%m-%d %H:%M:%S")
    @original_filename = params[:file].original_filename
    
    # display sample
    sample_count = 5
    i = 0
    @samples = []
    
    begin
      if iip.csv_data.lines.to_a.size <= 1
        flash[:error] = 'No data line in your CSV, check the encoding of the file<br/><br/>Header :<br/>'.html_safe +
          iip.csv_data

        redirect_to importer_index_path(:project_id => @project)

        return
      end

      CSV.new(iip.csv_data, {:headers=>true,
                            :encoding=>iip.encoding,
                             :quote_char=>iip.quote_char,
                             :col_sep=>iip.col_sep}).each do |row|
        @samples[i] = row
        i += 1
        if i >= sample_count
          break
        end
      end # do
    rescue Exception => e
      csv_data_lines = iip.csv_data.lines.to_a

      error_message = e.message +
        '<br/><br/>Header :<br/>'.html_safe +
        csv_data_lines[0]

      if csv_data_lines.size > 0
        error_message += '<br/><br/>Error on header or line :<br/>'.html_safe +
          csv_data_lines[@samples.size + 1]
      end

      flash[:error] = error_message

      redirect_to importer_index_path(:project_id => @project)

      return
    end

    if @samples.size > 0
      @headers = @samples[0].headers
    end
    
    missing_header_columns = ''
    @headers.each_with_index{|h, i|
      if h.nil?
        missing_header_columns += " #{i+1}"
      end
    }

    if missing_header_columns.present?
      flash[:error] = 'Column header missing : ' + missing_header_columns + " / #{@headers.size}" +
        '<br/><br/>Header :<br/>'.html_safe +
        iip.csv_data.lines.to_a[0]

      redirect_to importer_index_path(:project_id => @project)

      return
    end

    # fields
    @attrs = Array.new
    ISSUE_ATTRS.each do |attr|
      #@attrs.push([l_has_string?("field_#{attr}".to_sym) ? l("field_#{attr}".to_sym) : attr.to_s.humanize, attr])
      @attrs.push([l_or_humanize(attr, :prefix=>"field_"), attr])
    end
    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, cfield.name])
    end
    IssueRelation::TYPES.each_pair do |rtype, rinfo|
      @attrs.push([l_or_humanize(rinfo[:name]),rtype])
    end
    @attrs.sort!
  end
  
  # Returns the issue object associated with the given value of the given attribute.
  # Raises NoIssueForUniqueValue if not found or MultipleIssuesForUniqueValue
  def issue_for_unique_attr(unique_attr, attr_value, row_data)
    if @issue_by_unique_attr.has_key?(attr_value)
      return @issue_by_unique_attr[attr_value]
    end

    if unique_attr == "id"
      issues = [Issue.where(:id => attr_value).first]
    else
      # Use IssueQuery class Redmine >= 2.3.0
      begin
        if Module.const_get('IssueQuery') && IssueQuery.is_a?(Class)
          query_class = IssueQuery
        end
      rescue NameError
        query_class = Query
      end

      query = query_class.new(:name => "_importer", :project => @project)
      query.add_filter("status_id", "*", [1])
      query.add_filter(unique_attr, "=", [attr_value])
      
      issues = Issue.where(query.statement).includes([ :assigned_to, :status, :tracker, :project, :priority, :category, :fixed_version ]).limit(2)
    end
    
    if issues.size > 1
      @failed_count += 1
      @failed_issues[@failed_count] = row_data
      @messages << "Warning: Unique field #{unique_attr} with value '#{attr_value}' in issue #{@failed_count} has duplicate record"
      raise MultipleIssuesForUniqueValue, "Unique field #{unique_attr} with value '#{attr_value}' has duplicate record"
      else
      if issues.size == 0
        raise NoIssueForUniqueValue, "No issue with #{unique_attr} of '#{attr_value}' found"
      end
      issues.first
    end
  end

  # Returns the id for the given user or raises RecordNotFound
  # Implements a cache of users based on login name
  def user_for_login!(login)
    begin
      if !@user_by_login.has_key?(login)
        @user_by_login[login] = User.where(:login => login).first
      end
    rescue ActiveRecord::RecordNotFound
      if params[:use_anonymous]
        @user_by_login[login] = User.anonymous()
      else
        @unfound_class = "User"
        @unfound_key = login
        raise
      end
    end
    @user_by_login[login]
  end
  def user_id_for_login!(login)
    user = user_for_login!(login)
    user ? user.id : nil
  end
    
  
  # Returns the id for the given version or raises RecordNotFound.
  # Implements a cache of version ids based on version name
  # If add_versions is true and a valid name is given,
  # will create a new version and save it when it doesn't exist yet.
  def version_id_for_name!(project,name,add_versions)
    if !@version_id_by_name.has_key?(name)
      version = Version.where(:project_id => project.id, :name => name).first
      if !version
        if name && (name.length > 0) && add_versions
          version = project.versions.build(:name=>name)
          version.save
        else
          @unfound_class = "Version"
          @unfound_key = name
          raise ActiveRecord::RecordNotFound, "No version named #{name}"
        end
      end
      @version_id_by_name[name] = version.id
    end
    @version_id_by_name[name]
  end
  
  def result
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_issues = Hash.new
    @messages = Array.new
    @affect_projects_issues = Hash.new
    # This is a cache of previously inserted issues indexed by the value
    # the user provided in the unique column
    @issue_by_unique_attr = Hash.new
    # Cache of user id by login
    @user_by_login = Hash.new
    # Cache of Version by name
    @version_id_by_name = Hash.new
    
    # Retrieve saved import data
    iip = ImportInProgress.where(:user_id => User.current.id).first
    if iip == nil
      flash[:error] = "No import is currently in progress"
      return
    end
    if iip.created.strftime("%Y-%m-%d %H:%M:%S") != params[:import_timestamp]
      flash[:error] = "You seem to have started another import " \
          "since starting this one. " \
          "This import cannot be completed"
      return
    end
    
    default_tracker = params[:default_tracker]
    update_issue = params[:update_issue]
    unique_field = params[:unique_field].empty? ? nil : params[:unique_field]
    journal_field = params[:journal_field]
    update_other_project = params[:update_other_project]
    # Authorise update of closed issues optionnaly
    if update_issue
      update_closed_issues = params[:update_closed_issues]
    end

    ignore_non_exist = params[:ignore_non_exist]
    fields_map = {}
    params[:fields_map].each { |k, v| fields_map[k.unpack('U*').pack('U*')] = v }
    send_emails = params[:send_emails]
    add_categories = params[:add_categories]
    add_versions = params[:add_versions]
    unique_attr = fields_map[unique_field]
    unique_attr_checked = false  # Used to optimize some work that has to happen inside the loop   

    # attrs_map is fields_map's invert
    attrs_map = fields_map.invert

    # check params
    unique_error = nil
    if update_issue
      unique_error = l(:text_rmi_specify_unique_field_for_update)
    elsif attrs_map["parent_issue"] != nil
      unique_error = l(:text_rmi_specify_unique_field_for_column,:column => l(:field_parent_issue))
    else
      IssueRelation::TYPES.each_key do |rtype|
        if attrs_map[rtype]
          unique_error = l(:text_rmi_specify_unique_field_for_column,:column => l("label_#{rtype}".to_sym))
          break
        end
      end
    end
    if unique_error && unique_attr.blank?
      flash[:error] = unique_error
      return
    end
    CSV.new(iip.csv_data, {:headers=>true,
                           :encoding=>iip.encoding,
                           :quote_char=>iip.quote_char,
                           :col_sep=>iip.col_sep}).each do |row|

      project = Project.where(:name => row[attrs_map["project"]]).first
      if !project
        project = @project
      end

      begin
        row.each do |k, v|
          k = k.unpack('U*').pack('U*') if k.kind_of?(String)
          v = v.unpack('U*').pack('U*') if v.kind_of?(String)

          row[k] = v
        end

        tracker = Tracker.where( :name => row[attrs_map["tracker"]]).first
        status = IssueStatus.where( :name => row[attrs_map["status"]]).first
        author = attrs_map["author"] ? user_for_login!(row[attrs_map["author"]]) : User.current
        priority = Enumeration.where( :name => row[attrs_map["priority"]]).first
        category_name = row[attrs_map["category"]]
        category = IssueCategory.where(:project_id => project.id, :name => category_name).first
        if (!category) && category_name && category_name.length > 0 && add_categories
          category = project.issue_categories.build(:name => category_name)
          category.save
        end
        assigned_to = row[attrs_map["assigned_to"]] != nil ? user_for_login!(row[attrs_map["assigned_to"]]) : nil
        fixed_version_name = row[attrs_map["fixed_version"]].blank? ? nil : row[attrs_map["fixed_version"]]
        fixed_version_id = fixed_version_name ? version_id_for_name!(project,fixed_version_name,add_versions) : nil
        watchers = row[attrs_map["watchers"]]
        # new issue or find exists one
        issue = Issue.new
        journal = nil
        issue.project_id = project != nil ? project.id : @project.id
        issue.tracker_id = tracker != nil ? tracker.id : default_tracker
        issue.author_id = author != nil ? author.id : User.current.id
      rescue ActiveRecord::RecordNotFound
        @failed_count += 1
        @failed_issues[@failed_count] = row
        @messages << "Warning: When adding issue #{@failed_count} below, the #{@unfound_class} #{@unfound_key} was not found"
        next
      end

      # translate unique_attr if it's a custom field -- only on the first issue
      if !unique_attr_checked
        if unique_field && !ISSUE_ATTRS.include?(unique_attr.to_sym)
          issue.available_custom_fields.each do |cf|
            if cf.name == unique_attr
              unique_attr = "cf_#{cf.id}"
              break
            end
          end
        end
        unique_attr_checked = true
      end

      if update_issue
        begin
          issue = issue_for_unique_attr(unique_attr,row[unique_field],row)
          
          # ignore other project's issue or not
          if issue.project_id != @project.id && !update_other_project
            @skip_count += 1
            next
          end
          
          # ignore closed issue except reopen
          # Authorise update of closed issues optionnaly
          if !update_closed_issues && issue.status.is_closed?
            if status == nil || status.is_closed?
              @skip_count += 1
              next
            end
          end
          
          # init journal
          note = row[journal_field] || ''
          journal = issue.init_journal(author || User.current, 
            note || '')
            
          @update_count += 1
          
        rescue NoIssueForUniqueValue
          if ignore_non_exist
            @skip_count += 1
            next
          else
            @failed_count += 1
            @failed_issues[@failed_count] = row
            @messages << "Warning: Could not update issue #{@failed_count} below, no match for the value #{row[unique_field]} were found"
            next
          end
          
        rescue MultipleIssuesForUniqueValue
          @failed_count += 1
          @failed_issues[@failed_count] = row
          @messages << "Warning: Could not update issue #{@failed_count} below, multiple matches for the value #{row[unique_field]} were found"
          next
        end
      end
    
      # project affect
      if project == nil
        project = Project.where(:id => issue.project_id)
      end
      @affect_projects_issues.has_key?(project.name) ?
        @affect_projects_issues[project.name] += 1 : @affect_projects_issues[project.name] = 1

      # required attributes
      issue.status_id = status != nil ? status.id : issue.status_id
      issue.priority_id = priority != nil ? priority.id : issue.priority_id
      issue.subject = row[attrs_map["subject"]] || issue.subject
      
      # optional attributes
      description = row[attrs_map["description"]]
      issue.description = description ?
          description.gsub(/\r\n?|\\n|<br\s*\/?>/, "\n") : issue.description
      issue.category_id = category != nil ? category.id : issue.category_id
      issue.start_date = row[attrs_map["start_date"]].blank? ? nil : Date.parse(row[attrs_map["start_date"]])
      issue.due_date = row[attrs_map["due_date"]].blank? ? nil : Date.parse(row[attrs_map["due_date"]])
      issue.assigned_to_id = assigned_to != nil ? assigned_to.id : issue.assigned_to_id
      issue.fixed_version_id = fixed_version_id != nil ? fixed_version_id : issue.fixed_version_id
      issue.done_ratio = row[attrs_map["done_ratio"]] || issue.done_ratio
      issue.estimated_hours = row[attrs_map["estimated_hours"]] || issue.estimated_hours

      # parent issues
      begin
        parent_value = row[attrs_map["parent_issue"]]
        if parent_value.present?
          issue.parent_issue_id = issue_for_unique_attr(unique_attr,parent_value,row).id
        end
      rescue NoIssueForUniqueValue
        if ignore_non_exist
          @skip_count += 1
        else
          @failed_count += 1
          @failed_issues[@failed_count] = row
          @messages << "Warning: When setting the parent for issue #{@failed_count} below, no matches for the value #{parent_value} were found"
          next
        end
      rescue MultipleIssuesForUniqueValue
        @failed_count += 1
        @failed_issues[@failed_count] = row
        @messages << "Warning: When setting the parent for issue #{@failed_count} below, multiple matches for the value #{parent_value} were found"
        next
      end

      # custom fields
      custom_failed_count = 0
      issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, cf|
        value = row[attrs_map[cf.name]]
        if value.present?
          begin
            if cf.field_format == 'user'
              value = user_id_for_login!(value).to_s
            elsif cf.field_format == 'version'
              value = version_id_for_name!(project,value,add_versions).to_s
            elsif cf.field_format == 'date'
              value = value.to_date.to_s(:db)
            elsif cf.multiple? && cf.field_format == 'list'
              value = value.split(',').map(&:strip)
            elsif cf.field_format == 'text'
              value = value.gsub(/\r\n?|\\n|<br\s*\/?>/, "\n")
            end
            h[cf.id] = value
          rescue
            if custom_failed_count == 0
              custom_failed_count += 1
              @failed_count += 1
              @failed_issues[@failed_count] = row
            end
            @messages << "Warning: When trying to set custom field #{cf.name} on issue #{@failed_count} below, value #{value} was invalid"
          end
        end
        h
      end
      next if custom_failed_count > 0
      
      # watchers
      watcher_failed_count = 0
      if watchers
        addable_watcher_users = issue.addable_watcher_users
        watchers.split(',').each do |watcher|
          begin
            watcher_user = user_id_for_login!(watcher)
            if issue.watcher_users.include?(watcher_user)
              next
            end
            if addable_watcher_users.include?(watcher_user)
              issue.add_watcher(watcher_user)
            end
          rescue ActiveRecord::RecordNotFound
            if watcher_failed_count == 0
              @failed_count += 1
              @failed_issues[@failed_count] = row
            end
            watcher_failed_count += 1
            @messages << "Warning: When trying to add watchers on issue #{@failed_count} below, User #{watcher} was not found"
          end
        end
      end
      next if watcher_failed_count > 0

      unless issue.save()
        @failed_count += 1
        @failed_issues[@failed_count] = row
        @messages << "Warning: The following data-validation errors occurred on issue #{@failed_count} in the list below"
        issue.errors.each do |attr, error_message|
          @messages << "Error: #{attr} #{error_message}"
        end
      else
        if unique_field
          @issue_by_unique_attr[row[unique_field]] = issue
        end
        
        if send_emails
          if update_issue
            if Setting.notified_events.include?('issue_updated') && (!issue.current_journal.empty?)
              Mailer.deliver_issue_edit(issue.current_journal)
            end
          else
            if Setting.notified_events.include?('issue_added')
              Mailer.deliver_issue_add(issue)
            end
          end
        end

        # Issue relations
        begin
          IssueRelation::TYPES.each_pair do |rtype, rinfo|
            if !row[attrs_map[rtype]]
              next
            end
            other_issue = issue_for_unique_attr(unique_attr,row[attrs_map[rtype]],row)
            relations = issue.relations.select { |r| (r.other_issue(issue).id == other_issue.id) && (r.relation_type_for(issue) == rtype) }
            if relations.length == 0
              relation = IssueRelation.new( :issue_from => issue, :issue_to => other_issue, :relation_type => rtype )
              relation.save
            end
          end
        rescue NoIssueForUniqueValue
          if ignore_non_exist
            @skip_count += 1
            next
          end
        rescue MultipleIssuesForUniqueValue
          break
        end

        if journal
          journal
        end

        @handle_count += 1

      end
  
    end # do
    
    if @failed_issues.size > 0
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers
    end
    
    # Clean up after ourselves
    iip.delete
    
    # Garbage prevention: clean up iips older than 3 days
    ImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])
  end

private

  def find_project
    @project = Project.find(params[:project_id])
  end

  def flash_message(type, text)
    flash[type] ||= ""
    flash[type] += "#{text}<br/>"
  end
  
end
