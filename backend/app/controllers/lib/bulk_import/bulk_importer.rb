require_relative 'bulk_import_mixins'
require_relative 'agent_handler'
require_relative 'container_instance_handler'
require_relative 'digital_object_handler'
require_relative 'lang_handler'
require_relative 'notes_handler'
require_relative 'subject_handler'
require_relative '../../../lib/uri_resolver'
require 'nokogiri'
require 'pp'
require 'rubyXL'
require 'asutils'
include URIResolver


START_MARKER = /ArchivesSpace field code/.freeze
DO_START_MARKER = /ArchivesSpace digital object import field codes/.freeze

class BulkImporter

  def run
      Log.error('RUN')
      begin
        rows = initialize_info
        while @headers.nil? && (row = rows.next)
          @counter += 1
          if (row[0] && (row[0].value.to_s =~ @start_marker))
            @headers = row_values(row)
            Log.error("we have headers!")
            begin
              check_for_code_dups
            rescue Exception => e
              raise StopBulkImportException.new(e.message)
            end
            # Skip the human readable header too
            rows.next
            @counter += 1 # for the skipping
          end
        end
        begin
          while (row = rows.next)
            @counter += 1
            values = row_values(row)
            next if values.reject(&:nil?).empty?
            @row_hash = Hash[@headers.zip(values)]
            ao = nil
            begin
              @report.new_row(@counter)
              if @digital_load
                ao = process_do_row
              else
                ao = process_row
              end
              @rows_processed += 1
              @error_level = nil
            rescue StopBulkImportException => se
              @report.add_errors(I18n.t('bulk_import.error.stopped', :row => @counter, :msg => se.message))
              raise StopIteration.new
            rescue BulkImportException => e
              @error_rows += 1
              @report.add_errors( e.message)
              @error_level = @hier
            end
            @report.end_row
          end
        rescue StopIteration
          # we just want to catch this without processing further
        end
        if @rows_processed == 0
          raise BulkImportException.new( I18n.t('bulk_import.error.no_data'))
        end
      rescue Exception => e
        if e.is_a?( BulkImportException) || e.is_a?( StopBulkImportException)
          @report.add_terminal_error(I18n.t('bulk_import.error.excel', :errs => e.message), @counter)
        elsif e.is_a?(StopIteration) && @headers.nil?
         @report.add_terminal_error(I18n.t('bulk_import.error.no_header'), @counter)
        else # something else went wrong
          @report.add_terminal_error(I18n.t('bulk_import.error.system', :msg => e.message), @counter)
        Log.error("UNEXPECTED EXCEPTION on bulkimport load! #{e.message}")
        Log.error( e.backtrace.pretty_inspect)
        end
      end
      return @report
  end
    

  def initialize(input_file, opts = {}, current_user)
    @input_file = input_file
#        @batch = ASpaceImport::RecordBatch.new
    @opts = opts
    @current_user = current_user
    @report_out = []
    @report = BulkImportReport.new
    @headers
    @digital_load  = @opts.fetch(:digital_load,'') == 'true'

    if @digital_load
      @find_uri =  "/repositories/#{@opts[:repo_id]}/find_by_id/archival_objects"
      @resource_ref = "/repositories/#{@opts[:repo_id]}/resources/#{@opts[:id]}"
      @repo_id = @opts[:repo_id]
      @start_marker = DO_START_MARKER
    else
      @created_ao_refs = []
      @first_level_aos = []
      @archival_levels = CvList.new('archival_record_level', @current_user)
      @container_types = CvList.new('container_type', @current_user)
      @date_types = CvList.new('date_type', @current_user)
      @date_labels = CvList.new('date_label', @current_user)
      @date_certainty = CvList.new('date_certainty', @current_user)
      @extent_types = CvList.new('extent_extent_type', @current_user)
      @extent_portions = CvList.new('extent_portion', @current_user)
      @instance_types ||= CvList.new('instance_instance_type', @current_user)
      @parents = ParentTracker.new
      @start_marker = START_MARKER
    end
    @start_position
    @need_to_move = false
  end

  def initialize_handler_enums
    @cih = ContainerInstanceHandler.new(@current_user)
   # @doh = DigitalObjectHandler(@current_user)
    @sh = SubjectHandler.new(@current_user)
   # @ah = AgentHandler.new(@current_user)
   # @lh = LangHandler.new(@current_user)
  end
      
  private
  # save (create/update) the archival object, then revive it

  def ao_save(ao)
    revived = nil
    begin
      archObj = nil
      if ao.id.nil?
         archObj = ArchivalObject.create_from_json(ao)
      else
        obj = ArchivalObject.get_or_die(ao.id)
        Log.error(" archobj: \n\t#{obj.pretty_inspect}")
        archObj = obj.update_from_json(ao)
      end
      objs = ArchivalObject.sequel_to_jsonmodel([archObj])
      revived = objs[0] if !objs.empty?
    rescue ValidationException => ve
      raise BulkImportException.new(I18n.t('bulk_import.error.ao_validation', :err=>ve.errors))
    rescue  Exception => e
      Log.error("UNEXPECTED ao save error: #{e.message}\n#{ e.backtrace}")
      Log.error(ASUtils.jsonmodels_to_hashes(ao).pretty_inspect) if ao
      raise e
    end
    Log.error("revived? #{revived.pretty_inspect}")
    revived
  end

  # required fields for a digital object row: ead match, ao_ref_id and at least one of digital_object_link, thumbnail
  def check_do_row
    err_arr = []
    begin
      err_arr.push I18n.t('bulk_import.error.ref_id_miss') if @row_hash['ao_ref_id'].nil?
      obj_link = @row_hash['digital_object_link']
      thumb = @row_hash['thumbnail'] || @row_hash['Thumbnail']
      err_arr.push  I18n.t('bulk_import.error.dig_info_miss') if @row_hash['digital_object_link'].nil? && thumb.nil?
    end
    v = @row_hash['publish']
    @row_hash['publish'] = (v == '1')
    err_arr.join('; ')
  end

  # look for all the required fields to make sure they are legit
  # strip all the strings and turn publish and restrictions_flaginto true/false
  def check_row
    err_arr = []
    begin
      # we'll check hierarchical level first, in case there was a parent that didn't get created
      hier = @row_hash['hierarchy']
      if !hier
        err_arr.push I18n.t('bulk_import.error.hier_miss')
      else
        hier = hier.to_i
        # we bail if the parent wasn't created!
        return I18n.t('bulk_import.error.hier_below_error_level') if (@error_level && hier > @error_level)
        err_arr.push I18n.t('bulk_import.error.hier_zero') if hier < 1
        # going from a 1 to a 3, for example
        if (hier - 1) > @hier
          err_arr.push I18n.t('bulk_import.error.hier_wrong')
          if @hier == 0
            err_arr.push I18n.t('bulk_import.error.hier_wrong_resource')
            raise StopBulkImportException.new(err_arr.join(';'))
          end
        end
        @hier = hier
      end
      missing_title = @row_hash['title'].nil?
      #date stuff: if already missing the title, we have to make sure the date label is valid
      missing_date = [@row_hash['begin'],@row_hash['end'],@row_hash['expression']].reject(&:nil?).empty?
      if !missing_date
        begin
          label = @date_labels.value((@row_hash['dates_label'] || 'creation'))
        rescue Exception => e
          err_arr.push I18n.t('bulk_import.error.invalid_date_label', :what => e.message) if missing_title
          missing_date = true
        end
      end
      err_arr.push  I18n.t('bulk_import.error.title_and_date') if (missing_title && missing_date)
      # tree hierachy
      begin
        level = @archival_levels.value(@row_hash['level'])
      rescue Exception => e
        err_arr.push I18n.t('bulk_import.error.level')
      end
    rescue StopBulkImportException => se
      raise
    rescue Exception => e
      Log.error(["UNEXPLAINED EXCEPTION on check row", e.message, e.backtrace, @row_hash].pretty_inspect)
    end
    if err_arr.empty?
      @row_hash.each do |k, v|
        @row_hash[k] = v.strip if !v.nil?
        if k == 'publish'  || k == 'restrictions_flag'
          @row_hash[k] = (v == '1')
        end
      end
    end
    err_arr.join('; ')
  end
    
  def check_for_code_dups
    test = {}
    dups = ""
    @headers.each do |head|
      if test[head]
        dups = "#{dups} #{head},"
      else
        test[head] = true
      end
    end
    if !dups.empty?
      raise Exception.new( I18n.t('bulk_import.error.duplicates', :codes => dups))
    end
  end
  
  # create an archival_object
  def create_archival_object(parent_uri)
    ao = JSONModel(:archival_object).new._always_valid!
    ao.title = @row_hash['title'] if  @row_hash['title']
    ao.dates = create_dates
    #because the date may have been invalid, we should check if there's a title, otherwise bail
    if ao.title.nil? && ao.dates.empty?
      raise BulkImportException.new(I18n.t('bulk_import.error.title_and_date'))
    end
    ao.resource = {'ref' => @resource['uri']}
    ao.component_id =  @row_hash['unit_id'] if @row_hash['unit_id']
    ao.repository_processing_note = @row_hash['processing_note'] if @row_hash['processing_note']
    ao.level =  @archival_levels.value(@row_hash['level'])
    ao.other_level = @row_hash['other_level'] || 'unspecified' if ao.level == 'otherlevel'
    ao.publish = @row_hash['publish']
    ao.restrictions_apply = @row_hash['restrictions_flag']
    ao.parent = {'ref' => parent_uri} unless parent_uri.nil?
    begin
      ao.extents = create_extents
    rescue Exception => e
      @report.add_errors(e.message)
    end
    errs =  handle_notes(ao, @row_hash)
    @report.add_errors(errs) if !errs.empty?
    # we have to save the ao for the display_string
    begin
      Log.error("About to save #{ao.pretty_inspect}")
      ao = ao_save(ao)
      Log.error("Did we save? #{ao.id}")
    rescue Exception => e
      msg = I18n.t('bulk_import.error.initial_save_error', :title =>ao.title, :msg => e.message)
      raise BulkImportException.new(msg)
    end
    ao.instances = create_top_container_instances 
    if (dig_instance = DigitalObjectHandler.create(@row_hash, ao, @report))
      ao.instances ||= []
      ao.instances << dig_instance
    end
    subjs = process_subjects
    subjs.each {|subj| ao.subjects.push({'ref' => subj.uri})} unless subjs.empty?
    links = process_agents
    ao.linked_agents = links
    ao
  end
  def create_extents
    extents = []
    #TODO: fill this up
  end
  def create_dates
    dates = []
    cntr = 1
    substr = ''
    until [@row_hash["begin#{substr}"],@row_hash["end#{substr}"],@row_hash["expression#{substr}"]].reject(&:nil?).empty?
      date = create_date(@row_hash["dates_label#{substr}"],@row_hash["begin#{substr}"],@row_hash["end#{substr}"],@row_hash["date_type#{substr}"],@row_hash["expression#{substr}"],@row_hash["date_certainty#{substr}"])
      dates << date if date
      cntr +=1
      substr = "_#{cntr}"
    end
    return dates
  end

  def create_subjects
    subjs = []
    #TODO: fill this up
  end
  def create_top_container_instances
	  instances = []
	  cntr = 1
	  substr = ''
    until @row_hash["cont_instance_type#{substr}"].nil? && @row_hash["type_1#{substr}"].nil? && @row_hash["barcode#{substr}"].nil?
      begin
      	subcont = {'type_2' => @row_hash["type_2#{substr}"],
      		'indicator_2' => @row_hash["indicator_2#{substr}"],
      		'type_3' => @row_hash["type_3#{substr}"],
		      	'indicator_3' => @row_hash["indicator_3#{substr}"]}
      		
	      instance = @cih.create_container_instance(@row_hash["cont_instance_type#{substr}"],
	      @row_hash["type_1#{substr}"], @row_hash["indicator_1#{substr}"], @row_hash["barcode#{substr}"], @resource['uri'], @report, subcont)
      rescue Exception => e 
        @report.add_errors(I18n.t('bulk_import.error.no_tc', number: cntr.to_s, why: e.message))
        instance = nil
      end
      cntr +=1
      substr = "_#{cntr}"
      instances << instance if instance
    end
    return instances
  end

    # set up all the @ variables (except for @header)
  def initialize_info
    @orig_filename = @opts[:filename]
    @report_out = []
    @report = BulkImportReport.new
    @headers
    @digital_load = @opts[:digital_load] == 'true'
    @report.set_file_name(@orig_filename)
    initialize_handler_enums
    @resource = resolve_references(Resource.to_jsonmodel(@opts[:rid]),['repository'])
    @repository = @resource['repository']['ref']
    @hier = 1
    unless @digital_load
      @ao = nil
      Log.error("aoid |#{@opts[:aoid]}|")
      aoid = @opts[:aoid] || nil
      @resource_level = (aoid.nil? || aoid.strip.empty?)
      @first_one = false # to determine whether we need to worry about positioning
      if @resource_level
        @parents.set_uri(0, nil)
        @hier = 0
      else
        @ao = ArchivalObject.to_jsonmodel(Integer(aoid))
        @start_position = @ao.position
        parent = @ao.parent # we need this for sibling/child disabiguation later on
        @parents.set_uri(0, (parent ? ASUtils.jsonmodels_to_hashes(parent)['ref'] : nil))
        @parents.set_uri(1, @ao.uri)
        @first_one = true
        Log.error("start_pos: #{@start_position}, parents: #{@parents.pretty_inspect} ")
      end
    end
    @counter = 0
    @rows_processed = 0
    @error_rows = 0
    Log.error("About to open #{@input_file}")
    workbook = RubyXL::Parser.parse(@input_file)
    sheet = workbook[0]
    rows = sheet.enum_for(:each)
  end
  
  def process_agents
    agents = []
    #TODO: fill in
    agents
  end

  def process_do_row
    ret_str =  resource_match
    # mismatch of resource stops all other processing
    if ret_str.empty?
      ret_str = check_do_row
    end
    raise BulkImportException.new( I18n.t('bulk_import.row_error', :row => @counter, :errs => ret_str )) if !ret_str.empty?
    begin
      ao = archival_object_from_ref(@row_hash['ao_ref_id'])
      raise BulkImportException.new( I18n.t('bulk_import.row_error', :row => @counter, :errs => I18n.t('bulk_import.ref_id_notfound', :refid => @row_hash['ao_ref_id']))) if ao == nil
      @report.add_archival_object(ao)
      if ao.instances
        digs = []
        ao.instances.each {|instance| digs.append(1) if instance["instance_type"] == "digital_object" }
        unless digs.empty?
          raise  BulkImportException.new( I18n.t('bulk_import.row_error', :row => @counter, :errs => I18n.t('bulk_import.error.has_dig_obj')))
        end
      end
      if (dig_instance = DigitalObjectHandler.create(@row_hash, ao, @report))
        ao.instances ||= []
        ao.instances << dig_instance
        begin
          ao = ao_save(ao)
          @report.add_info(I18n.t('bulk_import.dig_assoc'))
        rescue BulkImportException => ee
          @report.add_errors(I18n.t('bulk_import.error.dig_unassoc', :msg =>ee.message))
        end
      end
    end
  end
 
  def process_row
    ret_str =  resource_match
    # mismatch of resource stops all other processing
    if ret_str.empty?
      ret_str = check_row
    end
    raise BulkImportException.new( I18n.t('bulk_import.row_error', :row => @counter, :errs => ret_str )) if !ret_str.empty?
    parent_uri = @parents.parent_for(@row_hash['hierarchy'].to_i)
    begin
      ao = create_archival_object(parent_uri)
      ao = ao_save(ao)
    rescue JSONModel::ValidationException => ve
      # ao won't have been created
      msg = I18n.t('bulk_import.error.second_save_error', :what => ve.errors, :title => ao.title, :pos => ao.position)
      @report.add_errors(msg)
    rescue  Exception => e
      Log.error("UNEXPECTED ON SECOND SAVE#{e.message}")
      Log.error(e.backtrace.pretty_inspect)
      Log.error( ASUtils.jsonmodels_to_hashes(ao).pretty_inspect)
      raise BulkImportException.new(e.message)
    end
    @report.add_archival_object(ao) if !ao.nil?
    @parents.set_uri(@hier, ao.uri)
    @created_ao_refs.push ao.uri
    if @hier == 1
      @first_level_aos.push ao.uri
      if @first_one && @start_position
        @need_to_move = (ao.position - @start_position) > 1
        @first_one = false
      end
    end
  end

  def process_subjects
    ret_subjs = []
    repo_id = @repository.split('/')[2]
    (1..10).each do |num|
      unless @row_hash["subject_#{num}_record_id"].nil? && @row_hash["subject_#{num}_term"].nil?
        subj = nil
        begin
          subj = @sh.get_or_create(@row_hash["subject_#{num}_record_id"],
            @row_hash["subject_#{num}_term"], @row_hash["subject_#{num}_type"], 
            @row_hash["subject_#{num}_source"], repo_id, num, @report)
          ret_subjs.push subj if subj
        rescue BulkImportException => e
          @report.add_errors(e.message)
        end
      end
    end
    ret_subjs
  end

  # make sure that the resource ead id from the form matches that in the spreadsheet
  # throws an exception if the designated resource ead doesn't match the spreadsheet row ead
  def resource_match
    ret_str = ''
    ret_str = I18n.t('bulk_import.error.res_ead') if @resource['ead_id'].nil?
    ret_str =  ' ' +  I18n.t('bulk_import.error.row_ead')  if @row_hash['ead'].nil?
    if ret_str.empty?
      ret_str =  I18n.t('bulk_import.error.ead_mismatch', :res_ead => @resource['ead_id'], :row_ead => @row_hash['ead']) if @resource['ead_id'] != @row_hash['ead']
    end
    ret_str
  end


  def row_values(row)
    (1...row.size).map {|i| (row[i] && row[i].value) ? (row[i].value.to_s.strip.empty? ? nil : row[i].value.to_s.strip) : nil}
  end
end