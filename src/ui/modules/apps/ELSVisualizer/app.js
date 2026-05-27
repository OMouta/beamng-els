angular.module('beamng.apps')
.directive('elsVisualizer', ['$interval', function ($interval) {
  return {
    templateUrl: '/ui/modules/apps/ELSVisualizer/app.html',
    replace: false,
    restrict: 'E',
    scope: false,
    controllerAs: 'els',
    controller: function ($scope) {
      var vm = this
      var timer = null

      vm.visible = false
      vm.installed = false
      vm.stage = 0
      vm.activeSiren = 0
      vm.manualHeld = false
      // label holds the real mounted-tone name, shown as the key's tooltip.
      vm.sirens = [
        { id: 1, active: false, label: 'Siren 1' },
        { id: 2, active: false, label: 'Siren 2' },
        { id: 3, active: false, label: 'Siren 3' },
        { id: 4, active: false, label: 'Siren 4' }
      ]

      // Reserved keys for upcoming features — rendered but inert until wired.
      vm.future = [
        { tag: 'TAKE\nDOWN' },
        { tag: 'LEFT\nALLEY' },
        { tag: 'RIGHT\nALLEY' },
        { tag: 'TRAF\nADV' }
      ]

      function update() {
        bngApi.activeObjectLua('elsControllerVE.getVisualizerState()', function (state) {
          $scope.$evalAsync(function () {
            if (!state) {
              vm.visible = false
              vm.installed = false
              return
            }

            vm.installed = !!state.controllerInstalled
            vm.visible = vm.installed
            vm.stage = state.stage || 0
            vm.activeSiren = state.activeSiren || 0
            vm.manualHeld = !!state.manualActive
            if (state.sirens) vm.sirens = state.sirens
          })
        })
      }

      vm.toggleLights = function () {
        bngApi.activeObjectLua('elsControllerVE.stageUp(1, nil)')
        update()
      }

      vm.siren = function (id) {
        bngApi.activeObjectLua('elsControllerVE.activateSiren(' + id + ', 1, nil)')
        update()
      }

      vm.standby = function () {
        bngApi.activeObjectLua('elsControllerVE.stopSiren()')
        update()
      }

      // Manual is momentary: plays while held (ignores light stage), stops on release.
      vm.manualStart = function () {
        if (!vm.installed || vm.manualHeld) return
        vm.manualHeld = true
        bngApi.activeObjectLua('elsControllerVE.startManual()')
      }

      vm.manualStop = function () {
        if (!vm.manualHeld) return
        vm.manualHeld = false
        bngApi.activeObjectLua('elsControllerVE.stopManual()')
        update()
      }

      update()
      timer = $interval(update, 250)

      $scope.$on('$destroy', function () {
        if (timer) $interval.cancel(timer)
      })
    }
  }
}])
