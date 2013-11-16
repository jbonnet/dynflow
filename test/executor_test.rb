require_relative 'test_helper'
require_relative 'code_workflow_example'

module Dynflow
  module ExecutorTest
    describe "executor" do

      include PlanAssertions

      [:world, :remote_world].each do |world_method|

        describe world_method.to_s do

          let(:world) { WorldInstance.send world_method }


          let :issues_data do
            [{ 'author' => 'Peter Smith', 'text' => 'Failing test' },
             { 'author' => 'John Doe', 'text' => 'Internal server error' }]
          end

          let :failing_issues_data do
            [{ 'author' => 'Peter Smith', 'text' => 'Failing test' },
             { 'author' => 'John Doe', 'text' => 'trolling' }]
          end

          let :finalize_failing_issues_data do
            [{ 'author' => 'Peter Smith', 'text' => 'Failing test' },
             { 'author' => 'John Doe', 'text' => 'trolling in finalize' }]
          end

          let :execution_plan do
            world.plan(CodeWorkflowExample::IncomingIssues, issues_data)
          end

          let :failed_execution_plan do
            plan = world.plan(CodeWorkflowExample::IncomingIssues, failing_issues_data)
            plan = world.execute(plan.id).value
            plan.state.must_equal :paused
            plan
          end

          let :finalize_failed_execution_plan do
            plan = world.plan(CodeWorkflowExample::IncomingIssues, finalize_failing_issues_data)
            plan = world.execute(plan.id).value
            plan.state.must_equal :paused
            plan
          end

          let :persisted_plan do
            world.persistence.load_execution_plan(execution_plan.id)
          end

          let :executor_class do
            Executors::Parallel
          end

          describe "execution plan state" do

            describe "after successful planning" do

              it "is pending" do
                execution_plan.state.must_equal :planed
              end

            end

            describe "after error in planning" do

              class FailingAction < Dynflow::Action
                def plan
                  raise "I failed"
                end
              end

              let :execution_plan do
                world.plan(FailingAction)
              end

              it "is stopped" do
                execution_plan.state.must_equal :stopped
              end

            end

            describe "when being executed" do

              let :execution_plan do
                world.plan(CodeWorkflowExample::IncomingIssue, { 'text' => 'get a break' })
              end

              before do
                TestPause.setup
                world.execute(execution_plan.id)
              end

              after do
                TestPause.teardown
              end

              it "is running" do
                TestPause.when_paused do
                  plan = world.persistence.load_execution_plan(execution_plan.id)
                  plan.state.must_equal :running
                  triage = plan.steps.values.find do |s|
                    s.is_a?(Dynflow::ExecutionPlan::Steps::RunStep) &&
                        s.action_class == Dynflow::CodeWorkflowExample::Triage
                  end
                  triage.state.must_equal :running
                  world.persistence.
                      load_step(triage.execution_plan_id, triage.id, world).
                      state.must_equal :running
                end
              end

              it "fails when trying to execute again" do
                TestPause.when_paused do
                  assert_raises(Dynflow::Error, /already running/) { world.execute(execution_plan.id) }
                end
              end
            end

            describe "when finished successfully" do

              it "is stopped" do
                world.execute(execution_plan.id).value.tap do |plan|
                  plan.state.must_equal :stopped
                end
              end
            end

            describe "when finished with error" do
              it "is paused" do
                world.execute(failed_execution_plan.id).value.tap do |plan|
                  plan.state.must_equal :paused
                end
              end
            end
          end

          describe "execution of run flow" do

            before do
              TestExecutionLog.setup
            end

            let :result do
              world.execute(execution_plan.id).value.tap do |result|
                raise result if result.is_a? Exception
              end
            end

            after do
              TestExecutionLog.teardown
            end

            let :persisted_plan do
              result
              world.persistence.load_execution_plan(execution_plan.id)
            end

            describe "suspended action" do

              let :execution_plan do
                world.plan(CodeWorkflowExample::DummySuspended, { :external_task_id => '123' })
              end

              it "doesn't cause problems" do
                result.result.must_equal :success
                result.state.must_equal :stopped
              end

              it 'does set times' do
                result.started_at.wont_be_nil
                result.ended_at.wont_be_nil
                result.execution_time.must_be :<, result.real_time
                result.execution_time.must_equal(
                    result.steps.inject(0) { |sum, (_, step)| sum + step.execution_time })

                plan_step = result.steps[1]
                plan_step.started_at.wont_be_nil
                plan_step.ended_at.wont_be_nil
                plan_step.execution_time.must_equal plan_step.real_time

                run_step = result.steps[2]
                run_step.started_at.wont_be_nil
                run_step.ended_at.wont_be_nil
                run_step.execution_time.must_be :<, run_step.real_time
              end

              describe 'handling errors in setup_progress_updates' do
                let :execution_plan do
                  world.plan(CodeWorkflowExample::DummySuspended,
                             external_task_id: '123',
                             text:             'troll setup_progress_updates')
                end

                it 'fails' do
                  assert_equal :error, result.result
                  assert_equal :paused, result.state
                  assert_equal :error,
                               result.steps.values.
                                   find { |s| s.is_a? Dynflow::ExecutionPlan::Steps::RunStep }.
                                   state
                end
              end

              describe 'progress' do
                before do
                  TestPause.setup
                  @running_plan = world.execute(execution_plan.id)
                end

                after do
                  @running_plan.wait
                  TestPause.teardown
                end

                describe 'plan with one action' do
                  let :execution_plan do
                    world.plan(CodeWorkflowExample::DummySuspended,
                               { external_task_id: '123',
                                 text:             'pause in progress 20%' })
                  end

                  it 'determines the progress of the execution plan in percents' do
                    TestPause.when_paused do
                      plan = world.persistence.load_execution_plan(execution_plan.id)
                      plan.progress.round(2).must_equal 0.2
                    end
                  end
                end

                describe 'plan with more action' do
                  let :execution_plan do
                    world.plan(CodeWorkflowExample::DummyHeavyProgress,
                               { external_task_id: '123',
                                 text:             'pause in progress 20%' })
                  end

                  it 'takes the steps weight in account' do
                    TestPause.when_paused do
                      plan = world.persistence.load_execution_plan(execution_plan.id)
                      plan.progress.round(2).must_equal 0.42
                    end
                  end
                end
              end

            end

            describe "action with empty flows" do

              let :execution_plan do
                world.plan(CodeWorkflowExample::Dummy, { :text => "dummy" }).tap do |plan|
                  assert_equal plan.run_flow.size, 0
                  assert_equal plan.finalize_flow.size, 0
                end.tap do |w|
                  w
                end
              end

              it "doesn't cause problems" do
                result.result.must_equal :success
                result.state.must_equal :stopped
              end

              it 'will not run again' do
                world.execute(execution_plan.id).value
                assert_raises(Dynflow::Error, /it's stopped/) { world.execute(execution_plan.id) }
              end

            end

            describe 'action with empty run flow but some finalize flow' do

              let :execution_plan do
                world.plan(CodeWorkflowExample::DummyWithFinalize, { :text => "dummy" }).tap do |plan|
                  assert_equal plan.run_flow.size, 0
                  assert_equal plan.finalize_flow.size, 1
                end
              end

              it "doesn't cause problems" do
                result.result.must_equal :success
                result.state.must_equal :stopped
              end

            end

            it "runs all the steps in the run flow" do
              assert_run_flow <<-EXECUTED_RUN_FLOW, persisted_plan
            Dynflow::Flows::Concurrence
              Dynflow::Flows::Sequence
                4: Triage(success) {"author"=>"Peter Smith", "text"=>"Failing test"} --> {"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}
                7: UpdateIssue(success) {"author"=>"Peter Smith", "text"=>"Failing test", "assignee"=>"John Doe", "severity"=>"medium"} --> {}
                9: NotifyAssignee(success) {"triage"=>{"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}} --> {}
              Dynflow::Flows::Sequence
                13: Triage(success) {"author"=>"John Doe", "text"=>"Internal server error"} --> {"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}
                16: UpdateIssue(success) {"author"=>"John Doe", "text"=>"Internal server error", "assignee"=>"John Doe", "severity"=>"medium"} --> {}
                18: NotifyAssignee(success) {"triage"=>{"classification"=>{"assignee"=>"John Doe", "severity"=>"medium"}}} --> {}
              EXECUTED_RUN_FLOW
            end

          end

          describe "execution of finalize flow" do

            before do
              TestExecutionLog.setup
              result = world.execute(execution_plan.id).value
              raise result if result.is_a? Exception
            end

            after do
              TestExecutionLog.teardown
            end

            describe "when run flow successful" do

              it "runs all the steps in the finalize flow" do
                assert_finalized(Dynflow::CodeWorkflowExample::IncomingIssues,
                                 { "issues" => [{ "author" => "Peter Smith", "text" => "Failing test" }, { "author" => "John Doe", "text" => "Internal server error" }] })
                assert_finalized(Dynflow::CodeWorkflowExample::Triage,
                                 { "author" => "Peter Smith", "text" => "Failing test" })
              end
            end

            describe "when run flow failed" do

              let :execution_plan do
                failed_execution_plan
              end

              it "doesn't run the steps in the finalize flow" do
                TestExecutionLog.finalize.size.must_equal 0
              end
            end

          end

          describe "re-execution of run flow after fix in run phase" do

            after do
              TestExecutionLog.teardown
            end

            let :resumed_execution_plan do
              failed_step = failed_execution_plan.steps.values.find do |step|
                step.state == :error
              end
              world.persistence.load_action(failed_step).tap do |action|
                action.input[:text] = "ok"
                world.persistence.save_action(failed_step.execution_plan_id, action)
              end
              TestExecutionLog.setup
              world.execute(failed_execution_plan.id).value
            end

            it "runs all the steps in the run flow" do
              resumed_execution_plan.state.must_equal :stopped
              resumed_execution_plan.result.must_equal :success

              run_triages = TestExecutionLog.run.find_all do |action_class, input|
                action_class == CodeWorkflowExample::Triage
              end
              run_triages.size.must_equal 1

              assert_run_flow <<-EXECUTED_RUN_FLOW, resumed_execution_plan
            Dynflow::Flows::Concurrence
              Dynflow::Flows::Sequence
                4: Triage(success) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"} --> {\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}
                7: UpdateIssue(success) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\", \"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"} --> {}
                9: NotifyAssignee(success) {\"triage\"=>{\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}} --> {}
              Dynflow::Flows::Sequence
                13: Triage(success) {\"author\"=>\"John Doe\", \"text\"=>\"ok\"} --> {\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}
                16: UpdateIssue(success) {\"author\"=>\"John Doe\", \"text\"=>\"trolling\", \"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"} --> {}
                18: NotifyAssignee(success) {\"triage\"=>{\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}} --> {}
              EXECUTED_RUN_FLOW
            end

          end
          describe "re-execution of run flow after fix in finalize phase" do

            after do
              TestExecutionLog.teardown
            end

            let :resumed_execution_plan do
              failed_step = finalize_failed_execution_plan.steps.values.find do |step|
                step.state == :error
              end
              world.persistence.load_action(failed_step).tap do |action|
                action.input[:text] = "ok"
                world.persistence.save_action(failed_step.execution_plan_id, action)
              end
              TestExecutionLog.setup
              world.execute(finalize_failed_execution_plan.id).value
            end

            it "runs all the steps in the finalize flow" do
              resumed_execution_plan.state.must_equal :stopped
              resumed_execution_plan.result.must_equal :success

              run_triages = TestExecutionLog.finalize.find_all do |action_class, input|
                action_class == CodeWorkflowExample::Triage
              end
              run_triages.size.must_equal 2

              assert_finalize_flow <<-EXECUTED_RUN_FLOW, resumed_execution_plan
                Dynflow::Flows::Sequence
                  5: Triage(success) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"} --> {\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}
                  10: NotifyAssignee(success) {\"triage\"=>{\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}} --> {}
                  14: Triage(success) {\"author\"=>\"John Doe\", \"text\"=>\"ok\"} --> {\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}
                  19: NotifyAssignee(success) {\"triage\"=>{\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}} --> {}
                  20: IncomingIssues(success) {\"issues\"=>[{\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"}, {\"author\"=>\"John Doe\", \"text\"=>\"trolling in finalize\"}]} --> {}
              EXECUTED_RUN_FLOW
            end

          end

          describe "re-execution of run flow after skipping" do

            after do
              TestExecutionLog.teardown
            end

            let :resumed_execution_plan do
              failed_step = failed_execution_plan.steps.values.find do |step|
                step.state == :error
              end
              failed_execution_plan.skip(failed_step)
              TestExecutionLog.setup
              world.execute(failed_execution_plan.id).value
            end

            it "runs all pending steps except skipped" do
              resumed_execution_plan.state.must_equal :stopped
              resumed_execution_plan.result.must_equal :success

              run_triages = TestExecutionLog.run.find_all do |action_class, input|
                action_class == CodeWorkflowExample::Triage
              end
              run_triages.size.must_equal 0

              assert_run_flow <<-EXECUTED_RUN_FLOW, resumed_execution_plan
            Dynflow::Flows::Concurrence
              Dynflow::Flows::Sequence
                4: Triage(success) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"} --> {\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}
                7: UpdateIssue(success) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\", \"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"} --> {}
                9: NotifyAssignee(success) {\"triage\"=>{\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}} --> {}
              Dynflow::Flows::Sequence
                13: Triage(skipped) {\"author\"=>\"John Doe\", \"text\"=>\"trolling\"} --> {}
                16: UpdateIssue(skipped) {\"author\"=>\"John Doe\", \"text\"=>\"trolling\", \"assignee\"=>Step(13).output[:classification][:assignee], \"severity\"=>Step(13).output[:classification][:severity]} --> {}
                18: NotifyAssignee(skipped) {\"triage\"=>Step(13).output} --> {}
              EXECUTED_RUN_FLOW

              assert_finalize_flow <<-FINALIZE_FLOW, resumed_execution_plan
            Dynflow::Flows::Sequence
              5: Triage(success) {\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"} --> {\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}
              10: NotifyAssignee(success) {\"triage\"=>{\"classification\"=>{\"assignee\"=>\"John Doe\", \"severity\"=>\"medium\"}}} --> {}
              14: Triage(skipped) {\"author\"=>\"John Doe\", \"text\"=>\"trolling\"} --> {}
              19: NotifyAssignee(skipped) {\"triage\"=>Step(13).output} --> {}
              20: IncomingIssues(success) {\"issues\"=>[{\"author\"=>\"Peter Smith\", \"text\"=>\"Failing test\"}, {\"author\"=>\"John Doe\", \"text\"=>\"trolling\"}]} --> {}
              FINALIZE_FLOW

            end
          end

          describe 'FlowManager' do
            let(:manager) { Executors::Parallel::FlowManager.new execution_plan, execution_plan.run_flow }

            def assert_next_steps(expected_next_step_ids, finished_step_id = nil, success = true)
              if finished_step_id
                step       = manager.execution_plan.steps[finished_step_id]
                next_steps = manager.cursor_index[step.id].what_is_next(step, success)
              else
                next_steps = manager.start
              end
              next_step_ids = next_steps.map(&:id)
              assert_equal Set.new(expected_next_step_ids), Set.new(next_step_ids)
            end

            describe 'what_is_next' do
              it 'returns next steps after required steps were finished' do
                assert_next_steps([4, 13])
                assert_next_steps([7], 4)
                assert_next_steps([9], 7)
                assert_next_steps([], 9)
                assert_next_steps([16], 13)
                assert_next_steps([18], 16)
                assert_next_steps([], 18)
                assert manager.done?
              end
            end

            describe 'what_is_next with errors' do

              it "doesn't return next steps if requirements failed" do
                assert_next_steps([4, 13])
                assert_next_steps([], 4, false)
              end


              it "is not done while other steps can be finished" do
                assert_next_steps([4, 13])
                assert_next_steps([], 4, false)
                assert !manager.done?
                assert_next_steps([], 13, false)
                assert manager.done?
              end
            end

          end

          describe 'Pool::RoundRobin' do
            let(:rr) { Dynflow::Executors::Parallel::Pool::RoundRobin.new }
            it do
              rr.next.must_be_nil
              rr.next.must_be_nil
              rr.must_be_empty
              rr.add 1
              rr.next.must_equal 1
              rr.next.must_equal 1
              rr.add 2
              rr.next.must_equal 2
              rr.next.must_equal 1
              rr.next.must_equal 2
              rr.delete 1
              rr.next.must_equal 2
              rr.next.must_equal 2
              rr.delete 2
              rr.next.must_be_nil
              rr.must_be_empty
            end
          end

          describe 'Pool::JobStorage' do
            FakeStep = Struct.new(:execution_plan_id)

            let(:storage) { Dynflow::Executors::Parallel::Pool::JobStorage.new }
            it do
              storage.must_be_empty
              storage.pop.must_be_nil
              storage.pop.must_be_nil

              storage.add s = FakeStep.new(1)
              storage.pop.must_equal s
              storage.must_be_empty
              storage.pop.must_be_nil

              storage.add s11 = FakeStep.new(1)
              storage.add s12 = FakeStep.new(1)
              storage.add s13 = FakeStep.new(1)
              storage.add s21 = FakeStep.new(2)
              storage.add s22 = FakeStep.new(2)
              storage.add s31 = FakeStep.new(3)

              storage.pop.must_equal s21
              storage.pop.must_equal s31
              storage.pop.must_equal s11
              storage.pop.must_equal s22
              storage.pop.must_equal s12
              storage.pop.must_equal s13

              storage.must_be_empty
              storage.pop.must_be_nil
            end
          end

        end
      end

      describe 'termination' do
        let(:world) { Dynflow::SimpleWorld.new }

        it 'executes until its done when terminating' do
          id, result = world.trigger(CodeWorkflowExample::Slow, 0.2)
          terminated = world.executor.terminate!
          terminated.wait
          result.must_be :ready?
          $slow_actions_done.must_equal 1
        end

        it 'it terminates when no work' do
          terminated = world.executor.terminate!
          terminated.wait
        end

      end
    end
  end
end