module CloudCrowd

  # A WorkUnit is an atomic chunk of work from a job, processing a single input
  # through a single action. The WorkUnits are run in parallel, with each worker
  # daemon processing one at a time. The splitting and merging stages of a job
  # are each run as a single WorkUnit.
  class WorkUnit < ActiveRecord::Base
    include ModelStatus
    
    belongs_to :job
    belongs_to :node_record
    
    validates_presence_of :job_id, :status, :input, :action
        
    named_scope :available, {:conditions => {:reservation => nil, :worker_pid => nil, :status => INCOMPLETE}}
    named_scope :reserved,  {:conditions => {:reservation => $$}}
    
    # Attempt to send a list of work_units to nodes with available capacity.
    # Do this in a separate thread so that the request can return, satisfied.
    # A single application server process stops the same WorkUnit from being
    # distributed to multiple nodes by reserving all the available ones.
    def self.distribute_to_nodes
      return unless WorkUnit.reserve_available
      work_units = WorkUnit.reserved
      available_nodes = NodeRecord.available
      until work_units.empty? do
        node = available_nodes.shift
        unit = work_units.first
        break unless node
        next unless node.actions.include? unit.action
        sent = node.send_work_unit(unit)
        if sent
          work_units.shift
          available_nodes.push(node) unless node.busy?
        end
      end
      WorkUnit.cancel_reservations
    end
    
    # Reserves all available WorkUnits. Returns false if there were none 
    # available.
    def self.reserve_available
      WorkUnit.available.update_all("reservation = #{$$}") > 0
    end
    
    def self.cancel_reservations
      WorkUnit.reserved.update_all('reservation = null')
    end
    
    def self.find_by_worker_name(name)
      pid, host = name.split('@')
      node = NodeRecord.find_by_host(host)
      node && node.work_units.find_by_worker_pid(pid)
    end
    
    def self.start(job, action, input, status)
      self.create(:job => job, :action => action, :input => input, :status => status)
    end
    
    # Mark this unit as having finished successfully.
    # Splitting work units are handled differently (an optimization) -- they 
    # immediately fire off all of their resulting WorkUnits for processing, 
    # without waiting for their splitting cousins to complete.
    def finish(output, time_taken)
      if splitting?
        [JSON.parse(parsed_output)].flatten.each do |new_input|
          WorkUnit.start(job, action, new_input, PROCESSING)
        end
        self.destroy
        job.set_next_status if job.done_splitting?
      else
        update_attributes({
          :status         => SUCCEEDED,
          :node_record    => nil,
          :worker_pid     => nil,
          :attempts       => attempts + 1,
          :output         => output,
          :time           => time_taken
        })
        job.check_for_completion
      end
    end
    
    # Mark this unit as having failed. May attempt a retry.
    def fail(output, time_taken)
      tries = self.attempts + 1
      return try_again if tries < CloudCrowd.config[:work_unit_retries]
      update_attributes({
        :status         => FAILED,
        :node_record    => nil,
        :worker_pid     => nil,
        :attempts       => tries,
        :output         => output,
        :time           => time_taken
      })
      self.job.check_for_completion
    end
    
    # Ever tried. Ever failed. No matter. Try again. Fail again. Fail better.
    def try_again
      update_attributes({
        :node_record  => nil,
        :worker_pid   => nil,
        :attempts     => self.attempts + 1
      })
    end
    
    # When a Worker checks out a WorkUnit, establish the connection between
    # WorkUnit and NodeRecord.
    def assign_to(node_record, worker_pid)
      update_attributes!(:node_record => node_record, :worker_pid => worker_pid)
    end
    
    # All output needs to be wrapped in a JSON object for consistency. Provides
    # the parsed version.
    def parsed_output
      JSON.parse(output)['output']
    end
    
    # The JSON representation of a WorkUnit shares the Job's options with all
    # its sister WorkUnits.
    def to_json
      {
        'id'        => self.id,
        'job_id'    => self.job_id,
        'input'     => self.input,
        'attempts'  => self.attempts,
        'action'    => self.action,
        'options'   => JSON.parse(self.job.options),
        'status'    => self.status
      }.to_json
    end
    
  end
end
