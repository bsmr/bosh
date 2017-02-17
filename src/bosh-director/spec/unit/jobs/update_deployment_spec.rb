require 'spec_helper'

module Bosh::Director::Jobs
  describe UpdateDeployment do
    subject(:job) { UpdateDeployment.new(manifest_content, cloud_config_id, runtime_config_id, options) }

    let(:config) { Bosh::Director::Config.load_hash(SpecHelper.spec_get_director_config)}
    let(:directory) { Support::FileHelpers::DeploymentDirectory.new }
    let(:manifest_content) { YAML.dump ManifestHelper.default_legacy_manifest }
    let(:cloud_config_id) { nil }
    let(:runtime_config_id) { nil }
    let(:options) { {} }
    let(:deployment_job) { Bosh::Director::DeploymentPlan::InstanceGroup.new(logger) }
    let(:task) {Bosh::Director::Models::Task.make(:id => 42, :username => 'user')}
    let(:errand_instance_group) do
      ig = Bosh::Director::DeploymentPlan::InstanceGroup.new(logger)
      ig.name = 'some-errand-instance-group'
      ig
    end

    before do
      Bosh::Director::App.new(config)
      allow(job).to receive(:task_id).and_return(task.id)
      allow(Time).to receive_messages(now: Time.parse('2016-02-15T09:55:40Z'))
    end

    describe '#perform' do
      let(:compile_step) { instance_double('Bosh::Director::DeploymentPlan::Steps::PackageCompileStep') }
      let(:update_step) { instance_double('Bosh::Director::DeploymentPlan::Steps::UpdateStep') }
      let(:notifier) { instance_double('Bosh::Director::DeploymentPlan::Notifier') }
      let(:job_renderer) { Bosh::Director::JobRenderer.create }
      let(:variables_interpolator) { instance_double('Bosh::Director::ConfigServer::VariablesInterpolator') }
      let(:planner_factory) do
        instance_double(
          'Bosh::Director::DeploymentPlan::PlannerFactory',
          create_from_manifest: planner,
        )
      end
      let(:planner) do
        instance_double(
          'Bosh::Director::DeploymentPlan::Planner',
          name: 'deployment-name',
          instance_groups_starting_on_deploy: [deployment_job],
          errand_instance_groups: [errand_instance_group],
          job_renderer: job_renderer
        )
      end

      let(:mock_manifest) do
        Bosh::Director::Manifest.new(YAML.load(manifest_content), nil, nil)
      end

      before do
        allow(job).to receive(:with_deployment_lock).and_yield.ordered
        allow(Bosh::Director::DeploymentPlan::Steps::PackageCompileStep).to receive(:new).and_return(compile_step)
        allow(Bosh::Director::DeploymentPlan::Steps::UpdateStep).to receive(:new).and_return(update_step)
        allow(Bosh::Director::DeploymentPlan::Notifier).to receive(:new).and_return(notifier)
        allow(Bosh::Director::JobRenderer).to receive(:create).and_return(job_renderer)
        allow(Bosh::Director::ConfigServer::VariablesInterpolator).to receive(:new).and_return(variables_interpolator)
        allow(Bosh::Director::DeploymentPlan::PlannerFactory).to receive(:new).and_return(planner_factory)
        allow(planner).to receive(:variables).and_return(Bosh::Director::DeploymentPlan::Variables.new([]))
        allow(variables_interpolator).to receive(:interpolate_template_spec_properties) {|properties, _| properties}
        allow(variables_interpolator).to receive(:interpolate_link_spec_properties) {|links_spec| links_spec}
        allow(variables_interpolator).to receive(:interpolate_deployment_manifest) { |manifest| manifest }
      end

      context 'variable set creation' do
        before do
          allow(update_step).to receive(:perform).ordered
          allow(planner).to receive(:bind_models)
          allow(planner).to receive(:instance_models).and_return([])
          allow(planner).to receive(:compile_packages)
          allow(planner).to receive(:instance_groups).and_return([deployment_job])
          allow(job_renderer).to receive(:render_job_instances).with(deployment_job.needed_instance_plans_for_variable_resolution)
          allow(notifier).to receive(:send_start_event)
          allow(notifier).to receive(:send_end_event).ordered
        end

        context "when options hash contains 'deploy' key" do
          let(:options) { {'deploy' => true } }
          let(:fixed_time) { Time.now }

          before do
            allow(Time).to receive(:now).and_return(fixed_time)
          end

          it 'should create a new variable set for the deployment' do
            deployment_model = Bosh::Director::Models::Deployment.make

            expect(Bosh::Director::Models::Deployment).to receive(:find).with({name: 'deployment-name'}).and_return(deployment_model)
            expect(deployment_model).to receive(:add_variable_set).with({:created_at=> fixed_time})
            job.perform
          end
        end

        context "when options hash does NOT contain 'deploy'" do
          let (:options) { {'deploy' => false } }

          it 'should NOT create a new variable set for the deployment' do
            expect(Bosh::Director::Models::Deployment).to_not receive(:find).with({name: 'deployment-name'})
            job.perform
          end
        end
      end

      context 'when all steps complete' do
        before do
          expect(notifier).to receive(:send_start_event).ordered
          expect(update_step).to receive(:perform).ordered
          expect(notifier).to receive(:send_end_event).ordered
          allow(job_renderer).to receive(:render_job_instances)
          allow(planner).to receive(:bind_models)
          allow(planner).to receive(:instance_models).and_return([])
          allow(planner).to receive(:validate_packages)
          allow(planner).to receive(:compile_packages)
          allow(planner).to receive(:instance_groups).and_return([deployment_job])
        end

        it 'binds models, renders templates, compiles packages, runs post-deploy scripts' do
          expect(planner).to receive(:bind_models)
          expect(job_renderer).to receive(:render_job_instances).with(deployment_job.needed_instance_plans_for_variable_resolution)
          expect(planner).to receive(:compile_packages)
          expect(job).to_not receive(:run_post_deploys)

          job.perform
        end

        it 'should clean job blob cache at the end of the deploy' do
          expect(job_renderer).to receive(:clean_cache!).ordered

          job.perform
        end

        context 'errands variables versioning' do
          let(:errand_properties) {{ 'some-key' => 'some-value'}}
          let(:resolved_links) {{ 'some-link-key' => 'some-link-value'}}

          before do
            allow(errand_instance_group).to receive(:properties).and_return(errand_properties)
            allow(errand_instance_group).to receive(:resolved_links).and_return(resolved_links)
          end

          it 'versions the variables in errands' do
            expect(variables_interpolator).to receive(:interpolate_template_spec_properties).with(errand_properties,'deployment-name')
            expect(variables_interpolator).to receive(:interpolate_link_spec_properties).with(resolved_links)

            job.perform
          end
        end

        context 'when variables exist in deployment plan' do
          let(:variables) do
            Bosh::Director::DeploymentPlan::Variables.new([{'name' => 'placeholder_a', 'type' => 'password'}])
          end

          let(:logger) { instance_double(Logging::Logger) }
          let(:client_factory) { instance_double(Bosh::Director::ConfigServer::ClientFactory) }
          let(:config_server_client) { instance_double(Bosh::Director::ConfigServer::DisabledClient) }

          before do
            allow(planner).to receive(:variables).and_return(variables)
            allow(Bosh::Director::ConfigServer::ClientFactory).to receive(:create).and_return(client_factory)
            allow(client_factory).to receive(:create_client).and_return(config_server_client)
          end

          it 'tries to generate the values through config server' do
            expect(config_server_client).to receive(:generate_values).with(variables, 'deployment-name')

            job.perform
          end
        end

        context 'when a cloud_config is passed in' do
          let(:cloud_config_id) { Bosh::Director::Models::CloudConfig.make.id }
          it 'uses the cloud config' do
            expect(job.perform).to eq('/deployments/deployment-name')
          end
        end

        context 'when a runtime_config is passed in' do
          let(:runtime_config_id) { Bosh::Director::Models::RuntimeConfig.make.id }

          before do
            allow(variables_interpolator).to receive(:interpolate_runtime_manifest)
          end

          it 'uses the runtime config' do
            expect(job.perform).to eq('/deployments/deployment-name')
          end
        end

        it 'performs an update' do
          expect(job.perform).to eq('/deployments/deployment-name')
        end

        context 'when the deployment makes no changes to existing vms' do
          it 'will not run post-deploy scripts' do
            expect(job).to_not receive(:run_post_deploys)

            job.perform
          end
        end

        context 'when the deployment makes changes to existing vms' do
          let (:instance_plan) { instance_double('Bosh::Director::DeploymentPlan::InstancePlan') }

          it 'will run post-deploy scripts' do
            allow(planner).to receive(:instance_groups).and_return([deployment_job])
            allow(deployment_job).to receive(:did_change).and_return(true)

            expect(Bosh::Director::PostDeploymentScriptRunner).to receive(:run_post_deploys_after_deployment)

            job.perform
          end
        end

        it 'should store new events' do
          expect {
            job.perform
          }.to change {
            Bosh::Director::Models::Event.count }.from(0).to(2)

          event_1 = Bosh::Director::Models::Event.first
          expect(event_1.user).to eq(task.username)
          expect(event_1.object_type).to eq('deployment')
          expect(event_1.deployment).to eq('deployment-name')
          expect(event_1.object_name).to eq('deployment-name')
          expect(event_1.task).to eq("#{task.id}")
          expect(event_1.timestamp).to eq(Time.now)

          event_2 = Bosh::Director::Models::Event.order(:id).last
          expect(event_2.parent_id).to eq(1)
          expect(event_2.user).to eq(task.username)
          expect(event_2.object_type).to eq('deployment')
          expect(event_2.deployment).to eq('deployment-name')
          expect(event_2.object_name).to eq('deployment-name')
          expect(event_2.task).to eq("#{task.id}")
          expect(event_2.timestamp).to eq(Time.now)
        end

        context 'when there are releases and stemcells' do
          before do
            deployment_model = Bosh::Director::Models::Deployment.make
            deployment_stemcell = Bosh::Director::Models::Stemcell.make(name: 'stemcell', version: 'version-1')
            deployment_release = Bosh::Director::Models::Release.make(name: 'release')
            deployment_release_version = Bosh::Director::Models::ReleaseVersion.make(version: 'version-1')
            deployment_release.add_version(deployment_release_version)
            deployment_model.add_stemcell(deployment_stemcell)
            deployment_model.add_release_version(deployment_release_version)
            allow(job).to receive(:current_deployment).and_return(nil, deployment_model)
          end

          it 'should store context of the event' do
            expect {
              job.perform
            }.to change {
              Bosh::Director::Models::Event.count }.from(0).to(2)
            expect(Bosh::Director::Models::Event.order(:id).last.context).to eq({'before' => {}, 'after' => {'releases' => ['release/version-1'], 'stemcells' => ['stemcell/version-1']}})
          end
        end

        context 'when `new` option is specified' do
          let (:options) { {'new' => true} }

          it 'should store new events with specific action' do
            expect {
              job.perform
            }.to change {
              Bosh::Director::Models::Event.count }.from(0).to(2)

            expect(Bosh::Director::Models::Event.first.action).to eq('create')
            expect(Bosh::Director::Models::Event.order(:id).last.action).to eq('create')
          end
        end

        context 'when `new` option is not specified' do
          it 'should define `update` deployment action' do
            expect {
              job.perform
            }.to change {
              Bosh::Director::Models::Event.count }.from(0).to(2)
            expect(Bosh::Director::Models::Event.first.action).to eq('update')
            expect(Bosh::Director::Models::Event.order(:id).last.action).to eq('update')
          end
        end
      end

      context 'when rendering templates fails' do
        let(:expected_result) do
          <<-EXPECTED.strip
Unable to render instance groups for deployment. Errors are:
  - Unable to render jobs for instance group 'my_instance_group_1'. Errors are:
    - Unable to render templates for job 'some_job1'. Errors are:
      - Failed to find variable '/TestDirector/simple/i_am_not_here_1' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_2' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_3' from config server: HTTP code '404'
  - Unable to render jobs for instance group 'my_instance_group_2'. Errors are:
    - Unable to render templates for job 'some_job2'. Errors are:
      - Failed to find variable '/TestDirector/simple/i_am_not_here_1' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_2' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_3' from config server: HTTP code '404'
          EXPECTED
        end

        let(:error_msgs) do
          <<-ERROR_MSGS.strip
- Unable to render jobs for instance group 'my_instance_group_1'. Errors are:
  - Unable to render templates for job 'some_job1'. Errors are:
    - Failed to find variable '/TestDirector/simple/i_am_not_here_1' from config server: HTTP code '404'
    - Failed to find variable '/TestDirector/simple/i_am_not_here_2' from config server: HTTP code '404'
    - Failed to find variable '/TestDirector/simple/i_am_not_here_3' from config server: HTTP code '404'
- Unable to render jobs for instance group 'my_instance_group_2'. Errors are:
  - Unable to render templates for job 'some_job2'. Errors are:
    - Failed to find variable '/TestDirector/simple/i_am_not_here_1' from config server: HTTP code '404'
    - Failed to find variable '/TestDirector/simple/i_am_not_here_2' from config server: HTTP code '404'
    - Failed to find variable '/TestDirector/simple/i_am_not_here_3' from config server: HTTP code '404'
          ERROR_MSGS
        end

        before do
          allow(notifier).to receive(:send_start_event)
          allow(planner).to receive(:bind_models)
          allow(job_renderer).to receive(:render_job_instances).and_raise(error_msgs)
          allow(planner).to receive(:instance_models).and_return([])
        end

        it 'formats the error messages' do
          expect {
            job.perform
          }.to raise_error { |error|
            expect(error.message).to eq(expected_result)
          }
        end

        context 'errand variable versioning fails' do
          let(:expected_result) do
            <<-EXPECTED.strip
Unable to render instance groups for deployment. Errors are:
  - Unable to render jobs for instance group 'my_instance_group_1'. Errors are:
    - Unable to render templates for job 'some_job1'. Errors are:
      - Failed to find variable '/TestDirector/simple/i_am_not_here_1' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_2' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_3' from config server: HTTP code '404'
  - Unable to render jobs for instance group 'my_instance_group_2'. Errors are:
    - Unable to render templates for job 'some_job2'. Errors are:
      - Failed to find variable '/TestDirector/simple/i_am_not_here_1' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_2' from config server: HTTP code '404'
      - Failed to find variable '/TestDirector/simple/i_am_not_here_3' from config server: HTTP code '404'
  - Unable to render jobs for instance group 'some-errand-instance-group'. Errors are:
    - Unable to render templates for job 'some_errand_job1'. Errors are:
      - Failed to find variable '/TestDirector/simple/some_property_error' from config server: HTTP code '404'
    - Unable to interpolate link 'some-link-name' properties; provided by 'some_provider_deployment_name' deployment. Errors are:
      - Failed to find variable '/TestDirector/simple/some_link_error' from config server: HTTP code '404'
            EXPECTED
          end

          let(:errand_properties_error) do
            <<-EXPECTED.strip
- Unable to render templates for job 'some_errand_job1'. Errors are:
  - Failed to find variable '/TestDirector/simple/some_property_error' from config server: HTTP code '404'
            EXPECTED
          end

          let(:errand_link_error) do
            <<-EXPECTED.strip
- Unable to interpolate link 'some-link-name' properties; provided by 'some_provider_deployment_name' deployment. Errors are:
  - Failed to find variable '/TestDirector/simple/some_link_error' from config server: HTTP code '404'
            EXPECTED
          end

          before do
            allow(errand_instance_group).to receive(:properties).and_raise(errand_properties_error)
            allow(errand_instance_group).to receive(:resolved_links).and_raise(errand_link_error)
          end

          it 'formats the error messages for service & errand instance groups' do
            expect {
              job.perform
            }.to raise_error { |error|
              expect(error.message).to eq(expected_result)
            }
          end
        end
      end

      context 'when job is being dry-run' do
        before do
          allow(job_renderer).to receive(:render_job_instances)
          allow(planner).to receive(:bind_models)
          allow(planner).to receive(:instance_models).and_return([])
          allow(planner).to receive(:validate_packages)
          allow(planner).to receive(:instance_groups).and_return([deployment_job])
        end

        let(:options) { { 'dry_run' => true } }

        it 'should exit before trying to create vms' do
          expect(planner).not_to receive(:compile_packages)
          expect(update_step).not_to receive(:perform)
          expect(Bosh::Director::PostDeploymentScriptRunner).not_to receive(:run_post_deploys_after_deployment)
          expect(notifier).not_to receive(:send_start_event)
          expect(notifier).not_to receive(:send_end_event)

          expect(job.perform).to eq('/deployments/deployment-name')
        end

        context 'when it fails the dry-run' do
          it 'should not send an error event to the health monitor' do
            expect(planner).to receive(:bind_models).and_raise
            expect(notifier).not_to receive(:send_error_event)

            expect{ job.perform }.to raise_error
          end
        end
      end

      context 'when the first step fails' do
        before do
          expect(notifier).to receive(:send_start_event).ordered
          expect(notifier).to receive(:send_error_event).ordered
        end

        it 'does not compile or update' do
          expect {
            job.perform
          }.to raise_error(Exception)
        end
      end
    end

    describe '#dry_run?' do
      context 'when job is being dry run' do
        let(:options) { {'dry_run' => true} }

        it 'should return true ' do
          expect(job.dry_run?).to be_truthy
        end
      end

      context 'when job is NOT being dry run' do
        it 'should return false' do
          expect(job.dry_run?).to be_falsey
        end
      end
    end
  end
end
